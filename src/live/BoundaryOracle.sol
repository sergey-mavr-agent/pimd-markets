// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./vendor/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "./vendor/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "./vendor/openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "./vendor/openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "./vendor/openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "./vendor/openzeppelin/contracts/utils/math/Math.sol";
import {MarketTypes as T} from "./libraries/MarketTypes.sol";
import {OracleRequest} from "./libraries/OracleRequest.sol";
import {PimdRegistry} from "./PimdRegistry.sol";
import {IBoundaryProofVerifier as BoundaryProofVerifier} from "./interfaces/IBoundaryProofVerifier.sol";
import {IOracleIntake} from "./interfaces/IOracleIntake.sol";

/// @dev The code of v1 BoundaryOracle (0x2CED79eba39EE972c6C4F7Dd51A08f28DC034555); only its registry differs.
/// The verifier is the fixed mainnet BoundaryProofVerifier, reached through its interface.
contract BoundaryOracle is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;
    error InvalidState();
    error InvalidAnswer();
    error InvalidPayment();
    uint256 public constant PROOF_WINDOW = 27 hours;
    uint256 public constant DISPUTE_WINDOW = 1 hours;
    uint256 public constant TIMEOUT = 3 days;
    uint256 public constant BOND = 10 ether;
    address public constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address public constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    bytes32 public constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    PimdRegistry public immutable registry;
    BoundaryProofVerifier public immutable verifier;
    mapping(uint32 => mapping(uint64 => uint256)) public price;
    mapping(uint32 => uint64) public latestBoundary;
    mapping(address => uint256) public credit;

    struct Proposal {
        address proposer;
        address challenger;
        address feePayer;
        uint64 deadline;
        uint64 firstBlock;
        uint64 boundary;
        uint32 version;
        uint8 received;
        bool finished;
        bool requested;
        uint256 proposed;
        uint256 cost;
        bytes32 anchorHash;
        uint256[3] answers;
        bytes32[3] requests;
    }

    struct Request {
        bytes32 proposal;
        bytes32 questionHash;
        uint8 hop;
        bool pending;
    }

    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }
    mapping(bytes32 => Proposal) private proposals;
    mapping(bytes32 => Request) public requests;
    mapping(bytes32 => bool) public usedAttestations;
    event PriceRecorded(uint32 indexed version, uint64 indexed boundary, uint256 price, bool proven);
    event Proposed(bytes32 indexed id, address indexed proposer, uint256 price, uint64 deadline, uint64 firstBlock);
    event Disputed(bytes32 indexed id, address indexed challenger, uint256 cost);
    event OracleRequested(bytes32 indexed requestId, bytes32 indexed proposal, uint8 hop, bytes32 questionHash);
    event ResolutionDeferred(bytes32 indexed proposal);
    event ProposalClosed(bytes32 indexed id, address winner, bool failed);
    event CreditWithdrawn(address indexed account, uint256 amount);

    constructor(PimdRegistry registry_, BoundaryProofVerifier verifier_) EIP712("IdentityMD Oracle", "2") {
        if (address(registry_) == address(0) || address(verifier_) == address(0)) revert InvalidState();
        registry = registry_;
        verifier = verifier_;
    }

    function proposalId(uint32 version, uint64 boundary) public pure returns (bytes32) {
        return keccak256(abi.encode(version, boundary));
    }

    function proposal(bytes32 id) external view returns (Proposal memory) {
        return proposals[id];
    }

    function prove(uint32 version, uint64 boundary, BoundaryProofVerifier.BlockProof[3] calldata proofs)
        external
        nonReentrant
    {
        if (
            block.chainid != 1 || !registry.isBoundary(boundary) || boundary > block.timestamp
                || block.timestamp > uint256(boundary) + PROOF_WINDOW || price[version][boundary] != 0
        ) revert InvalidState();
        uint256 p = verifier.verify(boundary, registry.asset(version), proofs);
        _record(version, boundary, p, true);
    }

    /// @notice True while a price for the boundary exists or can still be recorded by a proof, a new
    /// proposal, or a live proposal. Markets refuse trades whose start price can no longer exist.
    function priceable(uint32 version, uint64 boundary) external view returns (bool) {
        if (price[version][boundary] != 0 || block.timestamp + DISPUTE_WINDOW < uint256(boundary) + TIMEOUT) {
            return true;
        }
        Proposal storage p = proposals[proposalId(version, boundary)];
        if (p.proposer == address(0) || p.finished) return false;
        return p.challenger == address(0) || block.timestamp < uint256(boundary) + TIMEOUT;
    }

    /// @notice A refunded proposal (oracle failure or timeout) frees its slot: a new proposal may follow
    /// while the proposal window is open. A finalized or resolved proposal has recorded the price.
    function propose(uint32 version, uint64 boundary, uint256 proposed, uint64 firstBlock) external nonReentrant {
        registry.asset(version);
        bytes32 id = proposalId(version, boundary);
        if (
            block.chainid != 1 || !registry.isBoundary(boundary) || block.timestamp <= uint256(boundary) + PROOF_WINDOW
                || block.timestamp + DISPUTE_WINDOW >= uint256(boundary) + TIMEOUT || price[version][boundary] != 0
                || (proposals[id].proposer != address(0) && !proposals[id].finished) || proposed == 0
                || proposed > T.MAX_PRICE || firstBlock == 0 || uint256(firstBlock) + 2 >= block.number
        ) revert InvalidState();
        delete proposals[id];
        Proposal storage p = proposals[id];
        p.proposer = msg.sender;
        p.version = version;
        p.boundary = boundary;
        p.proposed = proposed;
        p.firstBlock = firstBlock;
        p.deadline = uint64(block.timestamp + DISPUTE_WINDOW);
        _pull(BOND);
        emit Proposed(id, msg.sender, proposed, p.deadline, firstBlock);
    }

    function oracleCost(uint32 version) public view returns (uint256 perQuestion, uint256 total) {
        try IOracleIntake(INTAKE).priceOf(ACTION, T.IMD) returns (uint256 cost) {
            perQuestion = cost;
        } catch {}
        if (perQuestion == 0) perQuestion = 0.5 ether;
        total = perQuestion * registry.asset(version).hops;
        if (total > BOND) revert InvalidPayment();
    }

    function dispute(uint32 version, uint64 boundary, uint256 maxCost) external nonReentrant {
        bytes32 id = proposalId(version, boundary);
        Proposal storage p = proposals[id];
        if (
            p.proposer == address(0) || p.finished || p.challenger != address(0) || msg.sender == p.proposer
                || block.timestamp >= p.deadline || block.timestamp >= uint256(boundary) + TIMEOUT
        ) revert InvalidState();
        if (maxCost > BOND) revert InvalidPayment();
        // An available, affordable oracle must be funded. If its price exceeds the entire losing
        // bond, accepting the challenge still prevents an objectively unchallengeable proposal.
        try this.oracleCost(version) returns (uint256, uint256 quoted) {
            if (maxCost < quoted) revert InvalidPayment();
        } catch {}
        p.challenger = msg.sender;
        _pull(BOND + maxCost);
        _tryRequest(id, maxCost);
        emit Disputed(id, msg.sender, p.cost);
    }

    /// @notice Anyone may retry an unavailable intake. Failure never reinstates an uncontested proposal.
    function retryResolution(uint32 version, uint64 boundary, uint256 maxCost) external nonReentrant {
        bytes32 id = proposalId(version, boundary);
        Proposal storage p = proposals[id];
        if (
            p.challenger == address(0) || p.finished || p.requested || block.timestamp >= uint256(boundary) + TIMEOUT
                || maxCost > BOND
        ) revert InvalidState();
        _pull(maxCost);
        _tryRequest(id, maxCost);
    }

    function _tryRequest(bytes32 id, uint256 maximum) private {
        try this.requestResolution(id, maximum) returns (uint256 cost) {
            proposals[id].cost = cost;
            proposals[id].feePayer = msg.sender;
            proposals[id].requested = true;
            credit[msg.sender] += maximum - cost;
        } catch {
            credit[msg.sender] += maximum;
            emit ResolutionDeferred(id);
        }
    }

    /// @dev An atomic subcall allows a failed second request to roll back the first payment as well.
    /// Only the guarded dispute/retry entry points can enter this function.
    function requestResolution(bytes32 id, uint256 maximum) external returns (uint256 total) {
        if (msg.sender != address(this)) revert InvalidState();
        Proposal storage p = proposals[id];
        (uint256 fee, uint256 cost) = oracleCost(p.version);
        total = cost;
        if (total > maximum) revert InvalidPayment();
        T.Asset memory a = registry.asset(p.version);
        IERC20(T.IMD).forceApprove(INTAKE, total);
        for (uint8 i; i < a.hops; ++i) {
            string memory q = OracleRequest.question(a, i, p.boundary, p.firstBlock, address(this), p.version);
            bytes32 rid = IOracleIntake(INTAKE)
                .requestWithFailure(
                    ACTION,
                    OracleRequest.body(q, p.firstBlock, address(this)),
                    IOracleIntake.Callback(address(this), this.onOracleResult.selector),
                    this.onFailure.selector,
                    T.IMD,
                    fee
                );
            if (rid == bytes32(0) || requests[rid].proposal != bytes32(0)) revert InvalidState();
            p.requests[i] = rid;
            bytes32 qh = OracleRequest.questionHash(q, p.firstBlock);
            requests[rid] = Request(id, qh, i, true);
            emit OracleRequested(rid, id, i, qh);
        }
        IERC20(T.IMD).forceApprove(INTAKE, 0);
    }

    /// @notice An unchallenged proposal is final once its challenge window has elapsed, whenever that is
    /// observed: the window always closes before the boundary's timeout, so a late proposal is not lost.
    function finalize(uint32 version, uint64 boundary) external nonReentrant {
        bytes32 id = proposalId(version, boundary);
        Proposal storage p = proposals[id];
        if (p.proposer == address(0) || p.finished || p.challenger != address(0) || block.timestamp < p.deadline) {
            revert InvalidState();
        }
        p.finished = true;
        credit[p.proposer] += BOND;
        _record(version, boundary, p.proposed, false);
        emit ProposalClosed(id, p.proposer, false);
    }

    function onOracleResult(bytes32 requestId, Attestation calldata a, bytes calldata signature) external nonReentrant {
        Request storage r = requests[requestId];
        Proposal storage p = proposals[r.proposal];
        if (msg.sender != INTAKE || !r.pending || p.finished) revert InvalidState();
        if (
            a.requestId == bytes32(0) || usedAttestations[a.requestId] || a.chainId != 1 || block.chainid != 1
                || a.questionHash != r.questionHash || a.answerType != 3 || a.answer.length != 32
                || a.fromBlock != p.firstBlock || a.toBlock != p.firstBlock + 2 || a.panelSize < 5 || a.quorum < 4
                || a.quorum > a.agreed || a.agreed > a.panelSize || a.issuedAt > block.timestamp
                || a.issuedAt < p.deadline - DISPUTE_WINDOW || a.expiresAt < block.timestamp || a.expiresAt < a.issuedAt
                || a.blockHash == bytes32(0) || block.timestamp >= uint256(p.boundary) + TIMEOUT
                || !SignatureChecker.isValidSignatureNow(SIGNER, digest(a), signature)
        ) revert InvalidAnswer();
        uint256 answer = abi.decode(a.answer, (uint256));
        if (answer == 0) revert InvalidAnswer();
        if (p.received == 0) p.anchorHash = a.blockHash;
        else if (p.anchorHash != a.blockHash) revert InvalidAnswer();
        r.pending = false;
        usedAttestations[a.requestId] = true;
        p.answers[r.hop] = answer;
        ++p.received;
        T.Asset memory asset = registry.asset(p.version);
        if (p.received == asset.hops) {
            uint256 value = uint256(asset.unitsPerShare) * 1e12;
            address cursor = asset.token;
            for (uint256 i; i < asset.hops; ++i) {
                bool forward = cursor == asset.path[i].currency0;
                value = forward
                    ? Math.mulDiv(value, p.answers[i], OracleRequest.HOP_BASE)
                    : Math.mulDiv(value, OracleRequest.HOP_BASE, p.answers[i]);
                cursor = forward ? asset.path[i].currency1 : asset.path[i].currency0;
            }
            if (value == 0 || value > T.MAX_PRICE) revert InvalidAnswer();
            p.finished = true;
            address winner = value == p.proposed ? p.proposer : p.challenger;
            credit[p.feePayer] += p.cost;
            credit[winner] += 2 * BOND - p.cost;
            _record(p.version, p.boundary, value, false);
            emit ProposalClosed(r.proposal, winner, false);
        }
    }

    function digest(Attestation calldata a) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                bytes.concat(
                    abi.encode(
                        TYPEHASH,
                        a.requestId,
                        a.chainId,
                        a.questionHash,
                        a.answerType,
                        keccak256(a.answer),
                        a.figure,
                        a.fromBlock
                    ),
                    abi.encode(
                        a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                    )
                )
            )
        );
    }

    function onFailure(bytes32 requestId, uint8 status, bytes32, uint16, uint16, bytes calldata) external nonReentrant {
        Request storage r = requests[requestId];
        if (msg.sender != INTAKE || !r.pending || (status != 1 && status != 2)) revert InvalidState();
        _refund(r.proposal);
    }

    /// @notice A disputed proposal the oracle never answered releases both bonds at the boundary's timeout.
    /// An unchallenged proposal is never timed out; it is finalized instead.
    function timeout(uint32 version, uint64 boundary) external nonReentrant {
        bytes32 id = proposalId(version, boundary);
        if (block.timestamp < uint256(boundary) + TIMEOUT || proposals[id].challenger == address(0)) {
            revert InvalidState();
        }
        _refund(id);
    }

    function _refund(bytes32 id) private {
        Proposal storage p = proposals[id];
        if (p.proposer == address(0) || p.finished) revert InvalidState();
        p.finished = true;
        credit[p.proposer] += BOND;
        if (p.challenger != address(0)) credit[p.challenger] += BOND;
        for (uint256 i; i < 3; ++i) {
            requests[p.requests[i]].pending = false;
        }
        emit ProposalClosed(id, address(0), true);
    }

    function withdrawCredit() external nonReentrant {
        uint256 amount = credit[msg.sender];
        if (amount == 0) revert InvalidPayment();
        credit[msg.sender] = 0;
        IERC20(T.IMD).safeTransfer(msg.sender, amount);
        emit CreditWithdrawn(msg.sender, amount);
    }

    function _pull(uint256 amount) private {
        uint256 beforeBalance = IERC20(T.IMD).balanceOf(address(this));
        IERC20(T.IMD).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(T.IMD).balanceOf(address(this)) - beforeBalance != amount) revert InvalidPayment();
    }

    function _record(uint32 version, uint64 boundary, uint256 value, bool proven) private {
        if (price[version][boundary] != 0) revert InvalidState();
        price[version][boundary] = value;
        if (boundary > latestBoundary[version]) latestBoundary[version] = boundary;
        emit PriceRecorded(version, boundary, value, proven);
    }
}

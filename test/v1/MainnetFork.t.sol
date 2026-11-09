// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundaryOracle} from "../../src/v1/BoundaryOracle.sol";
import {BoundaryProofVerifier} from "../../src/v1/BoundaryProofVerifier.sol";
import {PimdRegistry} from "../../src/v1/PimdRegistry.sol";
import {PimdSwap} from "../../src/v1/PimdSwap.sol";
import {PimdMarkets} from "../../src/v1/PimdMarkets.sol";
import {MarketTypes as T} from "../../src/v1/libraries/MarketTypes.sol";
import {MainnetFixture as F} from "./fixtures/MainnetFixture.sol";

/// @notice Explicit fork profile; the default offline suite replays the same historical proofs.
/// Run at block 26357170. No endpoint, key, or environment reads are embedded in these tests.
contract MainnetForkTest is Test {
    PimdRegistry internal registry;
    BoundaryOracle internal oracle;
    PimdSwap internal swapper;
    PimdMarkets internal markets;
    address internal alice = makeAddr("fork-alice");
    address internal bob = makeAddr("fork-bob");

    function setUp() public {
        require(block.chainid == 1 && block.number == 26357170, "run the fork profile at block 26357170");
        registry = new PimdRegistry(address(this));
        BoundaryProofVerifier verifier = new BoundaryProofVerifier();
        oracle = new BoundaryOracle(registry, verifier);
        swapper = new PimdSwap(registry);
        markets = new PimdMarkets(address(this), registry, oracle, swapper);
    }

    function test_realHistoryStateRootAccountAndPoolProofs() public {
        oracle.prove(1, F.BOUNDARY, F.proofs());
        assertEq(oracle.price(1, F.BOUNDARY), F.PRICE);
    }

    function test_realPoolManagerExactOutputWithNativeETHIntermediate() public {
        deal(T.IMD, address(this), 100e18);
        IERC20(T.IMD).approve(address(swapper), 100e18);
        uint256 before = IERC20(T.USDC).balanceOf(address(this));
        uint256 spent = swapper.exactOutput(1, 1e6, 100e18);
        assertGt(spent, 0);
        assertLe(spent, 100e18);
        assertEq(IERC20(T.USDC).balanceOf(address(this)) - before, 1e6);
        assertEq(IERC20(T.IMD).balanceOf(address(swapper)), 0);
    }

    function test_realSwapMaxInputFailureRollsBack() public {
        deal(T.IMD, address(this), 1e18);
        IERC20(T.IMD).approve(address(swapper), 1e18);
        vm.expectRevert();
        swapper.exactOutput(1, 100e6, 1);
        assertEq(IERC20(T.IMD).balanceOf(address(this)), 1e18);
    }

    function test_realTokensProofAndMirroredMarketWithIMDOnlyShort() public {
        oracle.prove(1, F.BOUNDARY, F.proofs());
        _deposit(alice);
        _deposit(bob);
        PimdMarkets.MarketSpec memory spec = PimdMarkets.MarketSpec(T.IMD, 0, F.BOUNDARY, 0);
        PimdMarkets.OrderInput memory i;
        i.action = PimdMarkets.Action.BuyDown;
        i.quantity = 10e6;
        i.limitPrice = 600_000;
        i.expiry = F.BOUNDARY + 3600;
        i.assetOnly = true;
        i.maxSwapInput = 10e18;
        i.feeBudget = 10e18;
        i.maxSteps = 4;
        vm.prank(bob);
        markets.place(spec, i);
        i.action = PimdMarkets.Action.BuyUp;
        i.assetOnly = false;
        i.feeBudget = 10e6;
        i.maxSwapInput = 0;
        vm.prank(alice);
        markets.place(spec, i);
        bytes32 id = markets.marketId(spec);
        (uint256 up,) = markets.positions(id, alice);
        (, uint256 down) = markets.positions(id, bob);
        assertEq(up, 10e6);
        assertEq(down, 10e6);
        assertEq(markets.market(id).reserveUSDC, 10e6);
        assertEq(markets.market(id).reserveAsset, 10e18);
        assertEq(IERC20(T.IMD).allowance(address(markets), address(swapper)), 0);
    }

    function _deposit(address user) private {
        deal(T.IMD, user, 100e18);
        deal(T.USDC, user, 100e6);
        vm.startPrank(user);
        IERC20(T.IMD).approve(address(markets), 100e18);
        IERC20(T.USDC).approve(address(markets), 100e6);
        markets.deposit(T.IMD, 100e18);
        markets.deposit(T.USDC, 100e6);
        vm.stopPrank();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/v1/LaunchToken.sol";
import {PimdRegistry} from "../../src/v1/PimdRegistry.sol";
import {BoundaryProofVerifier} from "../../src/v1/BoundaryProofVerifier.sol";
import {BoundaryOracle} from "../../src/v1/BoundaryOracle.sol";
import {PimdSwap} from "../../src/v1/PimdSwap.sol";
import {PimdMarkets} from "../../src/v1/PimdMarkets.sol";

contract FactoryFixture {
    function deploy(address owner)
        external
        returns (LaunchToken t, PimdRegistry r, BoundaryProofVerifier p, BoundaryOracle o, PimdSwap s, PimdMarkets m)
    {
        t = new LaunchToken();
        r = new PimdRegistry(owner);
        p = new BoundaryProofVerifier();
        o = new BoundaryOracle(r, p);
        s = new PimdSwap(r);
        m = new PimdMarkets(owner, r, o, s);
        require(t.balanceOf(address(this)) == 1e27 && t.totalSupply() == 1e27);
    }
}

contract DeploymentTest is Test {
    function test_emptyChainFactoryDeploymentSupplyOwnershipSizeAndOpcodes() public {
        address owner = makeAddr("launch-owner");
        FactoryFixture f = new FactoryFixture();
        (LaunchToken t, PimdRegistry r, BoundaryProofVerifier p, BoundaryOracle o, PimdSwap s, PimdMarkets m) =
            f.deploy(owner);
        assertEq(t.balanceOf(address(f)), 1e27);
        assertEq(r.owner(), owner);
        assertEq(m.owner(), owner);
        assertEq(address(m.registry()), address(r));
        assertEq(address(m.oracle()), address(o));
        assertEq(address(m.swapper()), address(s));
        address[6] memory contracts_ = [address(t), address(r), address(p), address(o), address(s), address(m)];
        for (uint256 i; i < contracts_.length; ++i) {
            bytes memory code = contracts_[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24576);
            bool reachable = true;
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op == 0x5b) reachable = true;
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
                if (op == 0 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
            }
        }
    }

    function test_constructorsDoNotCallCodeLessDependencies() public {
        address owner = makeAddr("owner");
        PimdRegistry r = PimdRegistry(makeAddr("registry-before-code"));
        BoundaryProofVerifier p = BoundaryProofVerifier(makeAddr("proof-before-code"));
        BoundaryOracle o = new BoundaryOracle(r, p);
        PimdSwap s = new PimdSwap(r);
        PimdMarkets m = new PimdMarkets(owner, r, o, s);
        assertEq(m.owner(), owner);
    }

    function test_zeroOwnerRejected() public {
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        new PimdRegistry(address(0));
    }
}

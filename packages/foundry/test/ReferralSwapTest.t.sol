// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    LiquidityManagement,
    PoolRoleAccounts,
    SwapKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import {IVaultExtension} from "@balancer-labs/v3-interfaces/contracts/vault/IVaultExtension.sol";
import {IVaultAdmin} from "@balancer-labs/v3-interfaces/contracts/vault/IVaultAdmin.sol";
import {IVaultMock} from "@balancer-labs/v3-interfaces/contracts/test/IVaultMock.sol";
import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import {CastingHelpers} from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import {BasicAuthorizerMock} from "@balancer-labs/v3-vault/contracts/test/BasicAuthorizerMock.sol";
import {ArrayHelpers} from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import {FixedPoint} from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import {BaseTest} from "@balancer-labs/v3-solidity-utils/test/foundry/utils/BaseTest.sol";
import {BaseVaultTest} from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";
import {VaultContractsDeployer} from "@balancer-labs/v3-vault/test/foundry/utils/VaultContractsDeployer.sol";

import {BatchRouterMock} from "@balancer-labs/v3-vault/contracts/test/BatchRouterMock.sol";
import {PoolFactoryMock} from "@balancer-labs/v3-vault/contracts/test/PoolFactoryMock.sol";
import {BalancerPoolToken} from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import {RouterMock} from "@balancer-labs/v3-vault/contracts/test/RouterMock.sol";
import {PoolMock} from "@balancer-labs/v3-vault/contracts/test/PoolMock.sol";

import {IRouterCommon} from "@balancer-labs/v3-interfaces/contracts/vault/IRouterCommon.sol";
import {ReferralSwapHook} from "../contracts/hooks/ReferralSwapHook.sol";
import {FixedPoint} from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import {VaultMockDeployer} from "@balancer-labs/v3-vault/test/foundry/utils/VaultMockDeployer.sol";

contract ReferralSwapTest is BaseVaultTest, VaultContractsDeployer {
    using CastingHelpers for address[];
    using FixedPoint for uint256;

    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    // Default counterparty.
    address payable internal winner;
    uint256 internal winnerKey;

    ReferralSwapHook public refHook;

    bytes32 bobLink_;

    ReferralSwapHook.ExtendedReferralSwapHookParams winnerParams;
    ReferralSwapHook.ExtendedReferralSwapHookParams aliceParams;

    // Overrides `setUp` to include a deployment for ReferralSwapHook.
    function setUp() public virtual override {
        BaseTest.setUp();
        (winner, winnerKey) = createUser("winner");
        users.push(winner);
        userKeys.push(winnerKey);

        vault = deployVaultMock();
        vm.label(address(vault), "vault");
        vaultExtension = IVaultExtension(vault.getVaultExtension());
        vm.label(address(vaultExtension), "vaultExtension");
        vaultAdmin = IVaultAdmin(vault.getVaultAdmin());
        vm.label(address(vaultAdmin), "vaultAdmin");
        authorizer = BasicAuthorizerMock(address(vault.getAuthorizer()));
        vm.label(address(authorizer), "authorizer");
        factoryMock = PoolFactoryMock(address(vault.getPoolFactoryMock()));
        vm.label(address(factoryMock), "factory");
        router = deployRouterMock(IVault(address(vault)), weth, permit2);
        vm.label(address(router), "router");
        batchRouter = deployBatchRouterMock(IVault(address(vault)), weth, permit2);
        vm.label(address(batchRouter), "batch router");
        feeController = vault.getProtocolFeeController();
        vm.label(address(feeController), "fee controller");

        refHook = new ReferralSwapHook(IVault(address(vault)), weth, permit2);
        vm.label(address(refHook), "refHook");

        // Here the Router is also the hook.
        poolHooksContract = address(refHook);
   
        pool = createPool();

        //  Approve vault allowances.
        for (uint256 i = 0; i < users.length; ++i) {
            address user = users[i];
            if (user != address(0)) {
                vm.startPrank(user);
                approveForSender();
                vm.stopPrank();
            }
        }

        if (pool != address(0)) {
            approveForPool(IERC20(pool));
        }
        //  Add initial liquidity.
        initPool();

        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));

        testCreateLink();

        winnerParams.kind = SwapKind.EXACT_IN;
        winnerParams.pool = pool;
        winnerParams.tokenIn = dai;
        winnerParams.tokenOut = usdc;
        winnerParams.amountGivenRaw = 23e18;
        winnerParams.limitRaw = 15e18;
        winnerParams.wethIsEth = false;
        winnerParams.userData = abi.encodePacked(bobLink_);

        aliceParams.kind = SwapKind.EXACT_IN;
        aliceParams.pool = pool;
        aliceParams.tokenIn = dai;
        aliceParams.tokenOut = usdc;
        aliceParams.amountGivenRaw = 19e18;
        aliceParams.limitRaw = 17e18;
        aliceParams.wethIsEth = false;
        aliceParams.userData = abi.encodePacked(bobLink_);
    }

    // Overrides approval to include NFTRouter.
    function approveForSender() internal override {
        for (uint256 i = 0; i < tokens.length; ++i) {
            tokens[i].approve(address(permit2), type(uint256).max);
            permit2.approve(address(tokens[i]), address(router), type(uint160).max, type(uint48).max);
            permit2.approve(address(tokens[i]), address(batchRouter), type(uint160).max, type(uint48).max);
            permit2.approve(address(tokens[i]), address(refHook), type(uint160).max, type(uint48).max);
        }
    }

    function approveForPool(IERC20 bpt) internal override {
        for (uint256 i = 0; i < users.length; ++i) {
            vm.startPrank(users[i]);

            bpt.approve(address(router), type(uint256).max);
            bpt.approve(address(batchRouter), type(uint256).max);
            bpt.approve(address(refHook), type(uint256).max);

            IERC20(bpt).approve(address(permit2), type(uint256).max);
            permit2.approve(address(bpt), address(router), type(uint160).max, type(uint48).max);
            permit2.approve(address(bpt), address(batchRouter), type(uint160).max, type(uint48).max);
            permit2.approve(address(bpt), address(refHook), type(uint160).max, type(uint48).max);

            vm.stopPrank();
        }
    }

    // Overrides pool creation 
    function _createPool(address[] memory tokens, string memory label) internal override returns (address) {
        PoolMock newPool = deployPoolMock(IVault(address(vault)), "NFT Pool", "NFT-POOL");
        vm.label(address(newPool), label);

        PoolRoleAccounts memory roleAccounts;
        roleAccounts.poolCreator = lp;

        factoryMock.registerTestPool(address(newPool), vault.buildTokenConfig(tokens.asIERC20()));

        vm.deal(payable(address(newPool)), defaultBalance);
        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(address(tokens[i]), address(newPool), defaultBalance);
        }

        return address(newPool);
    }

    function testCreateLink() public returns (bytes memory) {
        vm.startPrank(bob);
        bobLink_ = refHook.createReferralLink(10e16, 50e16);

        assert(refHook.referralLinks(bob) > 0);

        refHook.removeReferralLink();

        assertEq(refHook.referralLinks(bob), 0, "bobLink_ has not been removed");

        bobLink_ = refHook.createReferralLink(10e16, 50e16);
        vm.stopPrank();
    }

    function test_ReferralSwapHook_Sequence() public {
        uint256 alice_dai_before = dai.balanceOf(alice);
        uint256 alice_usdc_before = usdc.balanceOf(alice);

        uint256 winner_dai_before = dai.balanceOf(winner);
        uint256 winner_usdc_before = usdc.balanceOf(winner);

        uint256 amountOutA = testAlice_ReferralSwapHook_ExactIn();
        uint256 amountOutB = testWinner_ReferralSwapHook_ExactIn();
        testAlice_ReferralSwapHook_ExactIn();
        testWinner_ReferralSwapHook_ExactIn();

        uint256 alice_dai_after = dai.balanceOf(alice);
        uint256 alice_usdc_after = usdc.balanceOf(alice);
        uint256 winner_dai_after = dai.balanceOf(winner);
        uint256 winner_usdc_after = usdc.balanceOf(winner);

        uint256 aliceFee = aliceParams.amountGivenRaw - amountOutA;

        assertEq(usdc.balanceOf(alice), alice_usdc_before + (amountOutA.mulDown(2e18)));
        assertEq(dai.balanceOf(alice), alice_dai_before - (aliceParams.amountGivenRaw.mulDown(2e18)));
        assertEq(
            usdc.balanceOf(winner),
            winner_usdc_before + (winnerParams.amountGivenRaw.mulDown(2e18) + aliceFee.mulDown(2e18))
        );
        assertEq(dai.balanceOf(winner), winner_dai_before - (winnerParams.amountGivenRaw.mulDown(2e18)));
    }

    function testWinner_ReferralSwapHook_ExactIn() public returns (uint256) {
        uint256 winner_dai_before = dai.balanceOf(winner);
        uint256 winner_usdc_before = usdc.balanceOf(winner);

        vm.startPrank(winner);
        (uint256 amountCalculatedRawB, uint256 amountInRawB, uint256 amountOutRawB) = refHook.swap(
            winnerParams.kind,
            winnerParams.pool,
            winnerParams.tokenIn,
            winnerParams.tokenOut,
            winnerParams.amountGivenRaw,
            winnerParams.limitRaw,
            winnerParams.wethIsEth,
            winnerParams.userData
        );

        vm.stopPrank();

        uint256 referalHookSwapFeePercentage = refHook.referralFeePercentage(bobLink_);
        uint256 hookFee = aliceParams.amountGivenRaw.mulDown(referalHookSwapFeePercentage);
        assertGe(usdc.balanceOf(winner), winner_usdc_before + amountOutRawB);
        assertGe(dai.balanceOf(winner), winner_dai_before - amountInRawB);
        return amountOutRawB;
    }

    function testAlice_ReferralSwapHook_ExactIn() public returns (uint256) {
        // we call this function to make Alice fail to get the lucky number for test
        refHook.getRandomNumber();

        uint256 alice_dai_before = dai.balanceOf(alice);
        uint256 alice_usdc_before = usdc.balanceOf(alice);
        uint256 bob_dai_before = dai.balanceOf(bob);
        uint256 bob_usdc_before = usdc.balanceOf(bob);

        vm.startPrank(alice);
        (uint256 amountCalculatedRawA, uint256 amountInRawA, uint256 amountOutRawA) = refHook.swap(
            aliceParams.kind,
            aliceParams.pool,
            aliceParams.tokenIn,
            aliceParams.tokenOut,
            aliceParams.amountGivenRaw,
            aliceParams.limitRaw,
            aliceParams.wethIsEth,
            aliceParams.userData
        );

        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), alice_usdc_before + amountOutRawA);
        assertEq(dai.balanceOf(alice), alice_dai_before - amountInRawA);
        assertEq(dai.balanceOf(bob), bob_dai_before);
        assertGe(usdc.balanceOf(bob), bob_usdc_before);
        return amountOutRawA;
    }

    function testWinner_ReferralSwapHook_ExactOut() public returns (uint256) {
        uint256 winner_dai_before = dai.balanceOf(winner);
        uint256 winner_usdc_before = usdc.balanceOf(winner);
        uint256 bob_dai_before = dai.balanceOf(bob);
        uint256 bob_usdc_before = usdc.balanceOf(bob);
        vm.startPrank(winner);
        (uint256 amountCalculatedRawB, uint256 amountInRawB, uint256 amountOutRawB) = refHook.swap(
            SwapKind.EXACT_OUT,
            winnerParams.pool,
            winnerParams.tokenIn,
            winnerParams.tokenOut,
            winnerParams.amountGivenRaw,
            23e18,
            winnerParams.wethIsEth,
            winnerParams.userData
        );

        vm.stopPrank();

        uint256 referalHookSwapFeePercentage = refHook.referralFeePercentage(bobLink_);
        uint256 hookFee = aliceParams.amountGivenRaw.mulDown(referalHookSwapFeePercentage);
        assertGe(usdc.balanceOf(winner), winner_usdc_before + amountOutRawB);
        assertGe(dai.balanceOf(winner), winner_dai_before - amountInRawB);
        assertGt(dai.balanceOf(bob), winner_dai_before - amountInRawB);
        assertGe(dai.balanceOf(bob), bob_dai_before);
        assertEq(usdc.balanceOf(bob), bob_usdc_before);
        return amountOutRawB;
    }

    function testAlice_ReferralSwapHook_ExactOut() public returns (uint256) {
        // we call this function to make Alice fail to get the lucky number for test
        refHook.getRandomNumber();

        uint256 alice_dai_before = dai.balanceOf(alice);

        uint256 alice_usdc_before = usdc.balanceOf(alice);

        vm.startPrank(alice);
        (uint256 amountCalculatedRawA, uint256 amountInRawA, uint256 amountOutRawA) = refHook.swap(
            SwapKind.EXACT_OUT,
            aliceParams.pool,
            aliceParams.tokenIn,
            aliceParams.tokenOut,
            aliceParams.amountGivenRaw,
            20e18,
            aliceParams.wethIsEth,
            aliceParams.userData
        );

        vm.stopPrank();

        uint256 referalHookSwapFeePercentage = refHook.referralFeePercentage(bobLink_);
        uint256 hookFee = aliceParams.amountGivenRaw.mulDown(referalHookSwapFeePercentage);
        assertEq(usdc.balanceOf(alice), alice_usdc_before + amountOutRawA);
        assertEq(dai.balanceOf(alice), alice_dai_before - amountInRawA);

        return amountOutRawA;
    }
}

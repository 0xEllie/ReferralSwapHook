// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IWETH} from "@balancer-labs/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import {
    AfterSwapParams,
    VaultSwapParams,
    SwapKind,
    TokenConfig,
    HookFlags
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import {ReentrancyGuardTransient} from
    "@balancer-labs/v3-solidity-utils/contracts/openzeppelin/ReentrancyGuardTransient.sol";

import {RouterCommon} from "@balancer-labs/v3-vault/contracts/RouterCommon.sol";

abstract contract ReferralSwapRouter is RouterCommon, ReentrancyGuardTransient {
    using Address for address payable;
    using SafeCast for *;

    struct ExtendedReferralSwapHookParams {
        address sender;
        address receiver;
        SwapKind kind;
        address pool;
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountGivenRaw;
        uint256 limitRaw;
        bool wethIsEth;
        bytes userData;
    }

    constructor(IVault vault, IWETH weth, IPermit2 permit2) RouterCommon(vault, weth, permit2) {
        // solhint-disable-previous-line no-empty-blocks
    }

    /**
     *
     *                          Swap
     *
     */
    function _swap(
        address sender,
        address receiver,
        SwapKind kind,
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountGivenRaw,
        uint256 limitRaw,
        bool wethIsEth,
        bytes memory userData
    ) internal saveSender returns (uint256 amountCalculatedRaw, uint256 amountInRaw, uint256 amountOutRaw) {
        (amountCalculatedRaw, amountInRaw, amountOutRaw) = abi.decode(
            _vault.unlock(
                abi.encodeWithSelector(
                    ReferralSwapRouter.referralSwap.selector,
                    ExtendedReferralSwapHookParams({
                        sender: sender,
                        receiver: receiver,
                        pool: pool,
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        amountGivenRaw: amountGivenRaw,
                        kind: kind,
                        limitRaw: limitRaw,
                        wethIsEth: wethIsEth,
                        userData: userData
                    })
                )
            ),
            (uint256, uint256, uint256)
        );
    }

    function referralSwap(ExtendedReferralSwapHookParams calldata params)
        external
        nonReentrant
        onlyVault
        returns (uint256 amountCalculatedRaw, uint256 amountInRaw, uint256 amountOutRaw)
    {
        if (params.kind == SwapKind.EXACT_IN) {
            RouterCommon._takeTokenIn(params.sender, params.tokenIn, params.amountGivenRaw, params.wethIsEth);

            (amountCalculatedRaw, amountInRaw, amountOutRaw) = _vault.swap(
                VaultSwapParams({
                    kind: params.kind,
                    pool: params.pool,
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    amountGivenRaw: params.amountGivenRaw,
                    limitRaw: params.limitRaw,
                    userData: params.userData
                })
            );
            _vault.sendTo(params.tokenOut, params.sender, amountOutRaw);
        }

        if (params.kind == SwapKind.EXACT_OUT) {
            RouterCommon._takeTokenIn(params.sender, params.tokenIn, params.amountGivenRaw, params.wethIsEth);

            (amountCalculatedRaw, amountInRaw, amountOutRaw) = _vault.swap(
                VaultSwapParams({
                    kind: params.kind,
                    pool: params.pool,
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    amountGivenRaw: params.amountGivenRaw,
                    limitRaw: params.limitRaw,
                    userData: params.userData
                })
            );
            _vault.sendTo(params.tokenOut, params.sender, amountOutRaw);
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

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

abstract contract ReferalSwapRouter is RouterCommon, ReentrancyGuardTransient {
    using Address for address payable;
    using SafeCast for *;

    struct ExtendedReferalSwapHookParams {
        address sender;
        address receiver;
        SwapKind kind;
        address pool;
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountGivenRaw;
        uint256 limitRaw;
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
        bytes memory userData
    ) internal saveSender returns (uint256 amountCalculatedRaw, uint256 amountInRaw, uint256 amountOutRaw) {
      
       
        (amountCalculatedRaw, amountInRaw, amountOutRaw) = abi.decode(
            _vault.unlock(
                abi.encodeWithSelector(
                    ReferalSwapRouter.referralSwap.selector,
                    ExtendedReferalSwapHookParams({
                        sender: sender,
                        receiver: receiver,
                        pool: pool,
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        amountGivenRaw: amountGivenRaw,
                        kind: kind,
                        limitRaw: limitRaw,
                        userData: userData
                    })
                )
            ),
            (uint256, uint256, uint256)
        );
    }

    function referralSwap(ExtendedReferalSwapHookParams calldata params)
        external
        nonReentrant
        onlyVault
        returns (uint256 amountCalculatedRaw, uint256 amountInRaw, uint256 amountOutRaw)
    {

        if (params.kind == SwapKind.EXACT_IN) {
            // address(params.tokenIn).delegatecall(abi.encodeWithSelector(
            //         IERC20.transfer.selector,address(_vault), params.amountGivenRaw));
                params.tokenIn.transfer(address(_vault), params.amountGivenRaw);
            _vault.settle(params.tokenIn, params.limitRaw);
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
        }
        if (params.kind == SwapKind.EXACT_OUT) {
            params.tokenOut.transfer(address(_vault), params.amountGivenRaw);
            _vault.settle(params.tokenOut, params.limitRaw);
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
        }
    }
}

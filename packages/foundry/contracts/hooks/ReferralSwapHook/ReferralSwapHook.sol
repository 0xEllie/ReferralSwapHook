// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {EnumerableMap} from "@balancer-labs/v3-solidity-utils/contracts/openzeppelin/EnumerableMap.sol";

import {IRouterCommon} from "@balancer-labs/v3-interfaces/contracts/vault/IRouterCommon.sol";
import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {IWETH} from "@balancer-labs/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import {
    TokenConfig,
    LiquidityManagement,
    HookFlags,
    SwapKind,
    AfterSwapParams
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import {BaseHooks} from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";
import {FixedPoint} from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import {ReferralSwapRouter} from "./ReferralSwapRouter.sol";

/// @notice users can swap through a swapLink which gives them the opportunity to win the fee that users payed for the swap so far.
contract ReferralSwapHook is ReferralSwapRouter, BaseHooks {
    using FixedPoint for uint256;
    using EnumerableMap for EnumerableMap.IERC20ToUint256Map;
    using SafeERC20 for IERC20;

    // When calling `onAfterSwap`, a random number is generated. If the number is equal to LUCKY_NUMBER, the user will
    // win the accrued fees. It must be a number between 1 and MAX_NUMBER, or else nobody will win.
    uint8 public constant LUCKY_NUMBER = 10;
    // The chance of winning is 1/MAX_NUMBER (i.e. 5%).
    uint8 public constant MAX_NUMBER = 20;

    // This contract uses timestamps to update its withdrawal fee over time.
    //solhint-disable not-rely-on-time

    // Map of tokens with accrued fees.
    EnumerableMap.IERC20ToUint256Map private _tokensWithAccruedFees;

    uint256 public _counter = 0;

    mapping(address => bytes32) public referralLinks;

    mapping(bytes32 => uint256) public referralFeePercentage;

    mapping(bytes32 => uint256) public referrerShare;

    mapping(bytes32 => address) public referrers;

    /**
     * @notice A user has swaped tokenin to an associated pool
     * @param user The user who swaped with link to win the fees
     * @param pool The pool that user swaps token
     */
    event ReferalSwap(address indexed user, address indexed pool);

    /**
     * @notice A new `ReferalSwapHook` contract has been registered successfully for a given factory and pool.
     * @dev If the registration fails the call will revert, so there will be no event.
     * @param hooksContract This contract
     * @param pool The pool on which the hook was registered
     */
    event ReferalSwapHookRegistered(address indexed hooksContract, address indexed pool);

    /**
     * @notice The swap hook fee percentage has been changed.
     * @dev Note that the initial fee will be zero, and no event is emitted on deployment.
     * @param hooksContract The hooks contract charging the fee
     * @param hookFeePercentage The new hook swap fee percentage
     */
    event HookSwapFeePercentageChanged(address indexed hooksContract, uint256 hookFeePercentage);

    /**
     * @notice Fee collected and added to the lottery pot.
     * @dev The current user did not win the lottery.
     * @param hooksContract This contract
     * @param token The token in which the fee was collected
     * @param feeAmount The amount of the fee collected
     */
    event ReferralSwapFeeCollected(address indexed hooksContract, IERC20 indexed token, uint256 feeAmount);

    /**
     * @notice Lottery proceeds were paid to a lottery winner.
     * @param hooksContract This contract
     * @param winner Address of the lottery winner
     * @param token The token in which winnings were paid
     * @param amountWon The amount of tokens won
     */
    event ReferralSwapWinningsPaid(
        address indexed hooksContract, address indexed winner, IERC20 indexed token, uint256 amountWon
    );

    event ReferralLinkCreated(address indexed referrer, uint256 indexed feePercentage, uint256 indexed referrerShare);

    event ReferralLinkRemoved(address indexed referrer, bytes32 indexed refLink);

    event FeePercentageChanged(
        address indexed referrer, uint256 indexed newFeePercentage, uint256 indexed referrerShare
    );

    /**
     * @notice Hooks functions called from an external router.
     * @dev This contract inherits both `ReferralSwapRouter` and `BaseHooks`, and functions as is its own router.
     * @param router The address of the Router
     */
    error CannotUseExternalRouter(address router);

    modifier onlySelfRouter(address router) {
        _ensureSelfRouter(router);
        _;
    }

    modifier onlyReferrer() {
        require(referralLinks[msg.sender] > 0, "sender is not link owner");
        _;
    }

    constructor(IVault vault, IWETH weth, IPermit2 permit2) ReferralSwapRouter(vault, weth, permit2) {
        // solhint-disable-previous-line no-empty-blocks
    }

    /**
     *
     *                               Hook Functions
     *
     */

    /// @inheritdoc BaseHooks
    function onRegister(address, address pool, TokenConfig[] memory, LiquidityManagement calldata)
        public
        override
        onlyVault
        returns (bool)
    {
        // NOTICE: In real hooks, make sure this function is properly implemented (e.g. check the factory, and check
        // that the given pool is from the factory). Returning true unconditionally allows any pool, with any
        // configuration, to use this hook.

        emit ReferalSwapHookRegistered(address(this), pool);

        return true;
    }

    /// @inheritdoc BaseHooks
    function getHookFlags() public pure override returns (HookFlags memory) {
        HookFlags memory hookFlags;
        // `enableHookAdjustedAmounts` must be true for all contracts that modify the `amountCalculated`
        // in after hooks. Otherwise, the Vault will ignore any "hookAdjusted" amounts, and the transaction
        // might not settle. (It should be false if the after hooks do something else.)
        hookFlags.enableHookAdjustedAmounts = true;
        hookFlags.shouldCallAfterSwap = true;
        return hookFlags;
    }

    /**
     *
     *                               Router Functions
     *
     */
    function swap(
        SwapKind kind,
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountGivenRaw,
        uint256 limitRaw,
        bool wethIsEth,
        bytes memory userData
    ) external payable saveSender returns (uint256 amountCalculatedRaw, uint256 amountInRaw, uint256 amountOutRaw) {
        (amountCalculatedRaw, amountInRaw, amountOutRaw) = _swap(
            msg.sender, address(this), kind, pool, tokenIn, tokenOut, amountGivenRaw, limitRaw, wethIsEth, userData
        );

        emit ReferalSwap(msg.sender, pool);
    }

    /// @inheritdoc BaseHooks
    function onAfterSwap(AfterSwapParams calldata params)
        public
        override
        onlySelfRouter(params.router)
        returns (bool success, uint256 hookAdjustedAmountCalculatedRaw)
    {
        bytes32 refLink_ = abi.decode(params.userData, (bytes32));

        require(referralFeePercentage[refLink_] > 0, "link is not valid");

        uint8 drawnNumber_;

        drawnNumber_ = getRandomNumber();

        address referrer_ = referrers[refLink_];
        require(referrer_ != address(0), "referrer is not valid");

        hookAdjustedAmountCalculatedRaw = params.amountCalculatedRaw;

        uint256 referalHookSwapFeePercentage = referralFeePercentage[refLink_];

        if (referalHookSwapFeePercentage > 0) {
            uint256 hookFee = hookAdjustedAmountCalculatedRaw.mulDown(referalHookSwapFeePercentage);

            if (params.kind == SwapKind.EXACT_IN) {
                // For EXACT_IN swaps, the `amountCalculated` is the amount of `tokenOut`. The fee must be taken
                // from `amountCalculated`, so we decrease the amount of tokens the Vault will send to the caller.
                //
                // The preceding swap operation has already credited the original `amountCalculated`. Since we're
                // returning `amountCalculated - feeToPay` here, it will only register debt for that reduced amount
                // on settlement. This call to `sendTo` pulls `feeToPay` tokens of `tokenOut` from the Vault to this
                // contract, and registers the additional debt, so that the total debts match the credits and
                // settlement succeeds.

                uint256 feeToPay =
                    _chargeFeeOrPayWinner(referrer_, params.router, drawnNumber_, params.tokenOut, hookFee);

                if (feeToPay > 0) {
                    hookAdjustedAmountCalculatedRaw -= feeToPay;
                }
            } else {
                // For EXACT_OUT swaps, the `amountCalculated` is the amount of `tokenIn`. The fee must be taken
                // from `amountCalculated`, so we increase the amount of tokens the Vault will ask from the user.
                //
                // The preceding swap operation has already registered debt for the original `amountCalculated`.
                // Since we're returning `amountCalculated + feeToPay` here, it will supply credit for that increased
                // amount on settlement. This call to `sendTo` pulls `feeToPay` tokens of `tokenIn` from the Vault to
                // this contract, and registers the additional debt, so that the total debts match the credits and
                // settlement succeeds.

                uint256 feeToPay =
                    _chargeFeeOrPayWinner(referrer_, params.router, drawnNumber_, params.tokenIn, hookFee);
                if (feeToPay > 0) {
                    hookAdjustedAmountCalculatedRaw += feeToPay;
                }
            }
        }
        return (true, hookAdjustedAmountCalculatedRaw);
    }

    /**
     * @notice Generate a pseudo-random number.
     * @dev This external function was created to allow the test to access the same random number that will be used by
     * the `onAfterSwap` hook, so we can predict whether the current call is a winner. In real applications, this
     * function should not exist, or should return a different number every time, even if called in the same
     * transaction.
     *
     * @return number A pseudo-random number.for testing lucky occations it returns the LUCKY_NUMBER when counter is odd.
     */
    function getRandomNumber() public returns (uint8) {
        // Increment the counter to help randomize the number drawn in the next swap.
        _counter++;

        if (_counter % 2 == 0) {
            return LUCKY_NUMBER;
        }
        return _getRandomNumber();
    }
    // If drawnNumber == LUCKY_NUMBER, user wins the pot and pays no fees. Otherwise, the hook fee adds to the pot.

    function _chargeFeeOrPayWinner(address _referrer, address router, uint8 drawnNumber, IERC20 token, uint256 hookFee)
        private
        returns (uint256)
    {
        if (drawnNumber == LUCKY_NUMBER) {
            address user = IRouterCommon(router).getSender();

            // Iterating backwards is more efficient, since the last element is removed from the map on each iteration.
            for (uint256 i = _tokensWithAccruedFees.size; i > 0; i--) {
                (IERC20 feeToken,) = _tokensWithAccruedFees.at(i - 1);
                _tokensWithAccruedFees.remove(feeToken);

                uint256 totalAmount_ = feeToken.balanceOf(address(this));

                uint256 referrerAmount_ =
                    feeToken.balanceOf(address(this)).mulDown(referrerShare[referralLinks[_referrer]]);

                uint256 amountWon_ = totalAmount_ - referrerAmount_;

                if (totalAmount_ > 0) {
                    // There are multiple reasons to use a direct transfer of hook fees to the user instead of hook
                    // adjusted amounts:
                    //
                    // * We can transfer all fees from all tokens.
                    // * For EXACT_OUT transactions, the maximum prize we might give is amountsIn, because the maximum
                    //   discount is 100%.
                    // * We don't need to send tokens to the Vault and then settle, which would be more expensive than
                    //   transferring tokens to the user directly.
                    feeToken.safeTransfer(user, amountWon_);

                    feeToken.safeTransfer(_referrer, referrerAmount_);

                    emit ReferralSwapWinningsPaid(address(this), user, feeToken, amountWon_);
                }
            }
            // Winner pays no fees.
            return 0;
        } else {
            // Add token to the map of tokens with accrued fees.
            _tokensWithAccruedFees.set(token, 1);

            if (hookFee > 0) {
                // Collect fees from the Vault; the user will pay them when the router settles the swap.
                _vault.sendTo(token, address(this), hookFee);

                uint256 tokenbal = token.balanceOf(address(this));

                emit ReferralSwapFeeCollected(address(this), token, hookFee);
            }

            return hookFee;
        }
    }

    // Generates a "random" number from 1 to MAX_NUMBER.
    // Be aware that in real applications the random number must be generated with a help of an oracle, or some
    // other off-chain method. The output of this function is predictable on-chain.
    //
    function _getRandomNumber() private view returns (uint8) {
        return uint8((uint256(keccak256(abi.encodePacked(block.prevrandao, _counter))) % MAX_NUMBER) + 1);
    }

    function createReferralLink(uint256 _newFeePercentage, uint256 _referrerShare) external returns (bytes32) {
        require(msg.sender != address(0), "sender cannot be zero");
        bytes32 refLink_ = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        referralLinks[msg.sender] = refLink_;
        referralFeePercentage[refLink_] = _newFeePercentage;
        referrerShare[refLink_] = _referrerShare;
        referrers[refLink_] = msg.sender;
        emit ReferralLinkCreated(msg.sender, _newFeePercentage, _referrerShare);
        return refLink_;
    }

    // only link Owner(Referrer) should call this but doesnt need a modifire since it uses the msg.sender address ro remove the link
    function removeReferralLink() external returns (bool) {
        bytes32 refLink_ = referralLinks[msg.sender];
        referralFeePercentage[refLink_] = 0;
        referralLinks[msg.sender] = 0;
        referrerShare[refLink_] = 0;
        referrers[refLink_] = address(0);
        emit ReferralLinkRemoved(msg.sender, refLink_);
        true;
    }

    function changeReferralFeePercentage(uint256 _newFeePercentage, uint256 _referrerShare)
        external
        onlyReferrer
        returns (bool)
    {
        bytes32 refLink_ = referralLinks[msg.sender];
        referralFeePercentage[refLink_] = _newFeePercentage;
        referrerShare[refLink_] = _referrerShare;

        emit FeePercentageChanged(msg.sender, _newFeePercentage, _referrerShare);

        return true;
    }

    function _ensureSelfRouter(address router) private view {
        if (router != address(this)) {
            revert CannotUseExternalRouter(router);
        }
    }
}

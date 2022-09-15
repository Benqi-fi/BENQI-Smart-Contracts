pragma solidity 0.5.17;

import "./QiToken.sol";
import "./ErrorReporter.sol";
import "./PriceOracle.sol";
import "./ComptrollerInterface.sol";
import "./ComptrollerStorage.sol";
import "./Unitroller.sol";
import "./Governance/Qi.sol";

/**
 * @title Benqi's Comptroller Contract
 * @author Benqi
 */
contract Comptroller is ComptrollerVXStorage, ComptrollerInterface, ComptrollerErrorReporter, ExponentialNoError {
    /// @notice Emitted when an admin supports a market
    event MarketListed(QiToken qiToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(QiToken qiToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(QiToken qiToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(QiToken qiToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(QiToken qiToken, string action, bool pauseState);

    /// @notice Emitted when supplier reward speed is updated
    event SupplyRewardSpeedUpdated(uint8 rewardToken, QiToken indexed qiToken, uint newSupplyRewardSpeed);

    /// @notice Emitted when borrower reward speed is updated
    event BorrowRewardSpeedUpdated(uint8 rewardToken, QiToken indexed qiToken, uint newBorrowRewardSpeed);

    /// @notice Emitted when a new BENQI speed is set for a contributor
    event ContributorQiSpeedUpdated(address indexed contributor, uint newSpeed);

    /// @notice Emitted when BENQI or AVAX is distributed to a borrower
    event DistributedBorrowerReward(uint8 indexed tokenType, QiToken indexed qiToken, address indexed borrower, uint qiDelta, uint qiBorrowIndex);

    /// @notice Emitted when BENQI or AVAX is distributed to a supplier
    event DistributedSupplierReward(uint8 indexed tokenType, QiToken indexed qiToken, address indexed borrower, uint qiDelta, uint qiBorrowIndex);

    /// @notice Emitted when borrow cap for a qiToken is changed
    event NewBorrowCap(QiToken indexed qiToken, uint newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    /// @notice Emitted when BENQI is granted by admin
    event QiGranted(address recipient, uint amount);

    /// @notice The initial BENQI and AVAX index for a market
    uint224 public constant initialIndexConstant = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    // reward token type to show BENQI or AVAX
    uint8 public constant rewardQi = 0;
    uint8 public constant rewardAvax = 1;

    constructor() public {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (QiToken[] memory) {
        QiToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param qiToken The qiToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, QiToken qiToken) external view returns (bool) {
        return markets[address(qiToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param qiTokens The list of addresses of the qiToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory qiTokens) public returns (uint[] memory) {
        uint len = qiTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            QiToken qiToken = QiToken(qiTokens[i]);

            results[i] = uint(addToMarketInternal(qiToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param qiToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(QiToken qiToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(qiToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(qiToken);

        emit MarketEntered(qiToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param qiTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address qiTokenAddress) external returns (uint) {
        QiToken qiToken = QiToken(qiTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the qiToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = qiToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(qiTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(qiToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set qiToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete qiToken from the account’s list of assets */
        // load into memory for faster iteration
        QiToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == qiToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        QiToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.length--;

        emit MarketExited(qiToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param qiToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address qiToken, address minter, uint mintAmount) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[qiToken], "mint is paused");

        // Shh - currently unused
        mintAmount;

        if (!markets[qiToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(qiToken, minter);
        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param qiToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address qiToken, address minter, uint actualMintAmount, uint mintTokens) external {
        // Shh - currently unused
        qiToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param qiToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of qiTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address qiToken, address redeemer, uint redeemTokens) external returns (uint) {
        uint allowed = redeemAllowedInternal(qiToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(qiToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address qiToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[qiToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[qiToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, QiToken(qiToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param qiToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address qiToken, address redeemer, uint redeemAmount, uint redeemTokens) external {
        // Shh - currently unused
        qiToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param qiToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address qiToken, address borrower, uint borrowAmount) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[qiToken], "borrow is paused");

        if (!markets[qiToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[qiToken].accountMembership[borrower]) {
            // only qiTokens may call borrowAllowed if borrower not in market
            require(msg.sender == qiToken, "sender must be qiToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(QiToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[qiToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(QiToken(qiToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }


        uint borrowCap = borrowCaps[qiToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = QiToken(qiToken).totalBorrows();
            uint nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, QiToken(qiToken), 0, borrowAmount);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: QiToken(qiToken).borrowIndex()});
        updateAndDistributeBorrowerRewardsForToken(qiToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param qiToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address qiToken, address borrower, uint borrowAmount) external {
        // Shh - currently unused
        qiToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param qiToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address qiToken,
        address payer,
        address borrower,
        uint repayAmount) external returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[qiToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: QiToken(qiToken).borrowIndex()});
        updateAndDistributeBorrowerRewardsForToken(qiToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param qiToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address qiToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex) external {
        // Shh - currently unused
        qiToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param qiTokenBorrowed Asset which was borrowed by the borrower
     * @param qiTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address qiTokenBorrowed,
        address qiTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external returns (uint) {
        // Shh - currently unused
        liquidator;

        if (!markets[qiTokenBorrowed].isListed || !markets[qiTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint borrowBalance = QiToken(qiTokenBorrowed).borrowBalanceStored(borrower);
        uint maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
        if (repayAmount > maxClose) {
            return uint(Error.TOO_MUCH_REPAY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param qiTokenBorrowed Asset which was borrowed by the borrower
     * @param qiTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address qiTokenBorrowed,
        address qiTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens) external {
        // Shh - currently unused
        qiTokenBorrowed;
        qiTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param qiTokenCollateral Asset which was used as collateral and will be seized
     * @param qiTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address qiTokenCollateral,
        address qiTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (!markets[qiTokenCollateral].isListed || !markets[qiTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (QiToken(qiTokenCollateral).comptroller() != QiToken(qiTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(qiTokenCollateral, borrower);
        updateAndDistributeSupplierRewardsForToken(qiTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param qiTokenCollateral Asset which was used as collateral and will be seized
     * @param qiTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address qiTokenCollateral,
        address qiTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external {
        // Shh - currently unused
        qiTokenCollateral;
        qiTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param qiToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of qiTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address qiToken, address src, address dst, uint transferTokens) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(qiToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(qiToken, src);
        updateAndDistributeSupplierRewardsForToken(qiToken, dst);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param qiToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of qiTokens to transfer
     */
    function transferVerify(address qiToken, address src, address dst, uint transferTokens) external {
        // Shh - currently unused
        qiToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `qiTokenBalance` is the number of qiTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint qiTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, QiToken(0), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, QiToken(0), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param qiTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address qiTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, QiToken(qiTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param qiTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral qiToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        QiToken qiTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        QiToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            QiToken asset = assets[i];

            // Read the balances and exchange rate from the qiToken
            (oErr, vars.qiTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> avax (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * qiTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.qiTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with qiTokenModify
            if (asset == qiTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in qiToken.liquidateBorrowFresh)
     * @param qiTokenBorrowed The address of the borrowed qiToken
     * @param qiTokenCollateral The address of the collateral qiToken
     * @param actualRepayAmount The amount of qiTokenBorrowed underlying to convert into qiTokenCollateral tokens
     * @return (errorCode, number of qiTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address qiTokenBorrowed, address qiTokenCollateral, uint actualRepayAmount) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(QiToken(qiTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(QiToken(qiTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = QiToken(qiTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the comptroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
    	require(msg.sender == admin, "only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param qiToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(QiToken qiToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(qiToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(qiToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(qiToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param qiToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(QiToken qiToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(qiToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        qiToken.isQiToken(); // Sanity check to make sure its really a QiToken

        // Note that isQied is not in active use anymore
        markets[address(qiToken)] = Market({isListed: true, isQied: false, collateralFactorMantissa: 0});

        _addMarketInternal(address(qiToken));

        emit MarketListed(qiToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address qiToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != QiToken(qiToken), "market already added");
        }
        allMarkets.push(QiToken(qiToken));
    }


    /**
      * @notice Set the given borrow caps for the given qiToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
      * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
      * @param qiTokens The addresses of the markets (tokens) to change the borrow caps for
      * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
      */
    function _setMarketBorrowCaps(QiToken[] calldata qiTokens, uint[] calldata newBorrowCaps) external {
    	require(msg.sender == admin || msg.sender == borrowCapGuardian, "only admin or borrow cap guardian can set borrow caps"); 

        uint numMarkets = qiTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for(uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(qiTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(qiTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(QiToken qiToken, bool state) public returns (bool) {
        require(markets[address(qiToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(qiToken)] = state;
        emit ActionPaused(qiToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(QiToken qiToken, bool state) public returns (bool) {
        require(markets[address(qiToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(qiToken)] = state;
        emit ActionPaused(qiToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    /*** Benqi Distribution ***/

    /**
     * @notice Set reward speed for a single market
     * @param rewardType  0: Qi, 1: Avax
     * @param qiToken Market whose speed to update
     * @param newSupplyRewardSpeed New supply speed
     * @param newBorrowRewardSpeed New borrow speed
     */
    function setRewardSpeedInternal(uint8 rewardType, QiToken qiToken, uint newSupplyRewardSpeed, uint newBorrowRewardSpeed) internal {
        uint currentSupplyRewardSpeed = supplyRewardSpeeds[rewardType][address(qiToken)];
        uint currentBorrowRewardSpeed = borrowRewardSpeeds[rewardType][address(qiToken)];

        if (currentSupplyRewardSpeed != 0) {
            updateRewardSupplyIndex(rewardType, address(qiToken));
        } else if (newSupplyRewardSpeed != 0) {
            Market storage market = markets[address(qiToken)];
            require(market.isListed, "Market is not listed");

            if (rewardSupplyState[rewardType][address(qiToken)].index == 0 && rewardSupplyState[rewardType][address(qiToken)].timestamp == 0) {
                rewardSupplyState[rewardType][address(qiToken)] = RewardMarketState({
                    index: initialIndexConstant,
                    timestamp: safe32(getBlockTimestamp(), "block timestamp exceeds 32 bits")
                });
            }
        }

        if (currentBorrowRewardSpeed != 0) {
            Exp memory borrowIndex = Exp({ mantissa: qiToken.borrowIndex() });
            updateRewardBorrowIndex(rewardType, address(qiToken), borrowIndex);
        } else if (newBorrowRewardSpeed != 0) {
            Market storage market = markets[address(qiToken)];
            require(market.isListed, "Market is not listed");

            if (rewardBorrowState[rewardType][address(qiToken)].index == 0 && rewardBorrowState[rewardType][address(qiToken)].timestamp == 0) {
                rewardBorrowState[rewardType][address(qiToken)] = RewardMarketState({
                    index: initialIndexConstant,
                    timestamp: safe32(getBlockTimestamp(), "block timestamp exceeds 32 bits")
                });
            }

        }

        if (currentSupplyRewardSpeed != newSupplyRewardSpeed) {
            supplyRewardSpeeds[rewardType][address(qiToken)] = newSupplyRewardSpeed;
            emit SupplyRewardSpeedUpdated(rewardType, qiToken, newSupplyRewardSpeed);
        }

        if (currentBorrowRewardSpeed != newBorrowRewardSpeed) {
            borrowRewardSpeeds[rewardType][address(qiToken)] = newBorrowRewardSpeed;
            emit BorrowRewardSpeedUpdated(rewardType, qiToken, newBorrowRewardSpeed);
        }
    }

    /**
     * @notice Accrue BENQI to the market by updating the supply index
     * @param rewardType  0: Qi, 1: Avax
     * @param qiToken The market whose supply index to update
     */
    function updateRewardSupplyIndex(uint8 rewardType, address qiToken) internal {
        require(rewardType <= 1, "rewardType is invalid"); 
        RewardMarketState storage supplyState = rewardSupplyState[rewardType][qiToken];
        uint supplySpeed = supplyRewardSpeeds[rewardType][qiToken];
        uint blockTimestamp = getBlockTimestamp();
        uint deltaTimestamps = sub_(blockTimestamp, uint(supplyState.timestamp));
        if (deltaTimestamps > 0 && supplySpeed > 0) {
            uint supplyTokens = QiToken(qiToken).totalSupply();
            uint qiAccrued = mul_(deltaTimestamps, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(qiAccrued, supplyTokens) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: supplyState.index}), ratio);
            rewardSupplyState[rewardType][qiToken] = RewardMarketState({
                index: safe224(index.mantissa, "new index exceeds 224 bits"),
                timestamp: safe32(blockTimestamp, "block timestamp exceeds 32 bits")
            });
        } else if (deltaTimestamps > 0) {
            supplyState.timestamp = safe32(blockTimestamp, "block timestamp exceeds 32 bits");
        }
    }

    /**
     * @notice Accrue BENQI to the market by updating the borrow index
     * @param rewardType  0: Qi, 1: Avax
     * @param qiToken The market whose borrow index to update
     */
    function updateRewardBorrowIndex(uint8 rewardType, address qiToken, Exp memory marketBorrowIndex) internal {
        require(rewardType <= 1, "rewardType is invalid"); 
        RewardMarketState storage borrowState = rewardBorrowState[rewardType][qiToken];
        uint borrowSpeed = borrowRewardSpeeds[rewardType][qiToken];
        uint blockTimestamp = getBlockTimestamp();
        uint deltaTimestamps = sub_(blockTimestamp, uint(borrowState.timestamp));
        if (deltaTimestamps > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(QiToken(qiToken).totalBorrows(), marketBorrowIndex);
            uint qiAccrued = mul_(deltaTimestamps, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(qiAccrued, borrowAmount) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: borrowState.index}), ratio);
            rewardBorrowState[rewardType][qiToken] = RewardMarketState({
                index: safe224(index.mantissa, "new index exceeds 224 bits"),
                timestamp: safe32(blockTimestamp, "block timestamp exceeds 32 bits")
            });
        } else if (deltaTimestamps > 0) {
            borrowState.timestamp = safe32(blockTimestamp, "block timestamp exceeds 32 bits");
        }
    }

    /**
     * @notice Refactored function to calc and rewards accounts supplier rewards
     * @param qiToken The market to verify the mint against
     * @param account The acount to whom BENQI or AVAX is rewarded
     */
    function updateAndDistributeSupplierRewardsForToken(address qiToken, address account) internal {
        for (uint8 rewardType = 0; rewardType <= 1; rewardType++) {
            updateRewardSupplyIndex(rewardType, qiToken);
            distributeSupplierReward(rewardType, qiToken, account);
        }
    }

    /**
     * @notice Calculate BENQI/AVAX accrued by a supplier and possibly transfer it to them
     * @param rewardType  0: Qi, 1: Avax
     * @param qiToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute BENQI to
     */
    function distributeSupplierReward(uint8 rewardType, address qiToken, address supplier) internal {
        require(rewardType <= 1, "rewardType is invalid"); 
        RewardMarketState storage supplyState = rewardSupplyState[rewardType][qiToken];
        Double memory supplyIndex = Double({mantissa: supplyState.index});
        Double memory supplierIndex = Double({mantissa: rewardSupplierIndex[rewardType][qiToken][supplier]});
        rewardSupplierIndex[rewardType][qiToken][supplier] = supplyIndex.mantissa;

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = initialIndexConstant;
        }

        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint supplierTokens = QiToken(qiToken).balanceOf(supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        uint supplierAccrued = add_(rewardAccrued[rewardType][supplier], supplierDelta);
        rewardAccrued[rewardType][supplier] = supplierAccrued;
        emit DistributedSupplierReward(rewardType, QiToken(qiToken), supplier, supplierDelta, supplyIndex.mantissa);
    }

   /**
     * @notice Refactored function to calc and rewards accounts supplier rewards
     * @param qiToken The market to verify the mint against
     * @param borrower Borrower to be rewarded
     */
    function updateAndDistributeBorrowerRewardsForToken(address qiToken, address borrower, Exp memory marketBorrowIndex) internal {
        for (uint8 rewardType = 0; rewardType <= 1; rewardType++) {
            updateRewardBorrowIndex(rewardType, qiToken, marketBorrowIndex);
            distributeBorrowerReward(rewardType, qiToken, borrower, marketBorrowIndex);
        }
    }

    /**
     * @notice Calculate BENQI accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param rewardType  0: Qi, 1: Avax
     * @param qiToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute BENQI to
     */
    function distributeBorrowerReward(uint8 rewardType, address qiToken, address borrower, Exp memory marketBorrowIndex) internal {
        require(rewardType <= 1, "rewardType is invalid"); 
        RewardMarketState storage borrowState = rewardBorrowState [rewardType][qiToken];
        Double memory borrowIndex = Double({mantissa: borrowState.index});
        Double memory borrowerIndex = Double({mantissa: rewardBorrowerIndex[rewardType][qiToken][borrower]});
        rewardBorrowerIndex[rewardType][qiToken][borrower] = borrowIndex.mantissa;

        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            uint borrowerAmount = div_(QiToken(qiToken).borrowBalanceStored(borrower), marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
            uint borrowerAccrued = add_(rewardAccrued[rewardType][borrower], borrowerDelta);
            rewardAccrued[rewardType][borrower] = borrowerAccrued;
            emit DistributedBorrowerReward(rewardType, QiToken(qiToken), borrower, borrowerDelta, borrowIndex.mantissa);
        }
    }

    /**
     * @notice Claim all the benqi accrued by holder in all markets
     * @param holder The address to claim BENQI for
     */
    function claimReward(uint8 rewardType, address payable holder) public {
        return claimReward(rewardType,holder, allMarkets);
    }

    /**
     * @notice Claim all the benqi accrued by holder in the specified markets
     * @param holder The address to claim BENQI for
     * @param qiTokens The list of markets to claim BENQI in
     */
    function claimReward(uint8 rewardType, address payable holder, QiToken[] memory qiTokens) public {
        address payable [] memory holders = new address payable[](1);
        holders[0] = holder;
        claimReward(rewardType, holders, qiTokens, true, true);
    }

    /**
     * @notice Claim all Benqi or Avax  accrued by the holders
     * @param rewardType  0 means Qi   1 means Avax
     * @param holders The addresses to claim AVAX for
     * @param qiTokens The list of markets to claim AVAX in
     * @param borrowers Whether or not to claim AVAX earned by borrowing
     * @param suppliers Whether or not to claim AVAX earned by supplying
     */
    function claimReward(uint8 rewardType, address payable[] memory holders, QiToken[] memory qiTokens, bool borrowers, bool suppliers) public payable {
        require(rewardType <= 1, "rewardType is invalid");
        for (uint i = 0; i < qiTokens.length; i++) {
            QiToken qiToken = qiTokens[i];
            require(markets[address(qiToken)].isListed, "market must be listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: qiToken.borrowIndex()});
                updateRewardBorrowIndex(rewardType,address(qiToken), borrowIndex);
                for (uint j = 0; j < holders.length; j++) {
                    distributeBorrowerReward(rewardType,address(qiToken), holders[j], borrowIndex);
                    grantRewardInternal(rewardType, holders[j], rewardAccrued[rewardType][holders[j]]);
                }
            }
            if (suppliers == true) {
                updateRewardSupplyIndex(rewardType,address(qiToken));
                for (uint j = 0; j < holders.length; j++) {
                    distributeSupplierReward(rewardType,address(qiToken), holders[j]);
                    grantRewardInternal(rewardType, holders[j], rewardAccrued[rewardType][holders[j]]);
                }
            }
        }
    }

    /**
     * @notice Transfer QI/AVAX to the user
     * @dev Note: If there is not enough BENQI/AVAX, we do not perform the transfer all.
     * @param user The address of the user to transfer AVAX to
     * @param amount The amount of AVAX to (possibly) transfer
     * @return The amount of AVAX which was NOT transferred to the user
     */
    function grantRewardInternal(uint8 rewardType, address payable user, uint amount) internal {
        if (rewardType == 0) {
            Qi benqi = Qi(qiAddress);
            uint qiRemaining = benqi.balanceOf(address(this));
            if (amount > 0 && amount <= qiRemaining) {
                rewardAccrued[rewardType][user] = 0;
                benqi.transfer(user, amount);
                return;
            }
        } else if (rewardType == 1) {
            uint avaxRemaining = address(this).balance;
            if (amount > 0 && amount <= avaxRemaining) {
                rewardAccrued[rewardType][user] = 0;
                (bool success, ) = user.call.value(amount).gas(4029)("");
                require(success, "Transfer failed.");
                return;
            }
        }
        rewardAccrued[rewardType][user] = amount;
    }

    /*** Benqi Distribution Admin ***/

    /**
     * @notice Transfer BENQI to the recipient
     * @dev Note: If there is not enough BENQI, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer BENQI to
     * @param amount The amount of BENQI to (possibly) transfer
     */
    function _grantQi(address recipient, uint amount) public {
        require(adminOrInitializing(), "only admin can grant benqi");
        require(amount > 0, "amount must be greater than zero");
        require(amount <= Qi(qiAddress).balanceOf(address(this)), "insufficient benqi for grant");
        Qi(qiAddress).transfer(recipient, amount);
        emit QiGranted(recipient, amount);
    }

    /**
     * @notice Set reward speed for a single market
     * @param rewardType 0 = QI, 1 = AVAX
     * @param qiToken The market whose reward speed to update
     * @param supplyRewardSpeed New supply reward speed for the market
     * @param borrowRewardSpeed New borrow reward speed for the market
     */
    function _setRewardSpeed(uint8 rewardType, QiToken qiToken, uint supplyRewardSpeed, uint borrowRewardSpeed) public {
        require(rewardType <= 1, "rewardType is invalid"); 
        require(adminOrInitializing(), "only admin can set reward speed");
        setRewardSpeedInternal(rewardType, qiToken, supplyRewardSpeed, borrowRewardSpeed);
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (QiToken[] memory) {
        return allMarkets;
    }

    function getBlockTimestamp() public view returns (uint) {
        return block.timestamp;
    }

    /**
     * @notice Set the QI token address
     */
    function setQiAddress(address newQiAddress) public {
        require(msg.sender == admin);
        qiAddress = newQiAddress;
    }

    /**
     * @notice payable function needed to receive AVAX
     */
    function () payable external {
    }
}

// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "./StakedAvaxStorage.sol";


contract StakedAvax is
    IERC20Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    StakedAvaxStorage
{
    using SafeMathUpgradeable for uint;

    /// @notice Emitted when a user stakes AVAX
    event Submitted(address indexed user, uint avaxAmount, uint shareAmount);

    /// @notice Emitted when a user requests sAVAX to be converted back to AVAX
    event UnlockRequested(address indexed user, uint shareAmount);

    /// @notice Emitted when a user cancel a pending unlock request
    event UnlockCancelled(address indexed user, uint unlockRequestedAt, uint shareAmount);

    /// @notice Emitted when a user redeems delegated AVAX
    event Redeem(address indexed user, uint unlockRequestedAt, uint shareAmount, uint avaxAmount);

    /// @notice Emitted when a user redeems sAVAX which was not burned for AVAX withing the `redeemPeriod`.
    event RedeemOverdueShares(address indexed user, uint shareAmount);

    /// @notice Emitted when a warden withdraws AVAX for delegation
    event Withdraw(address indexed user, uint amount);

    /// @notice Emitted when a warden deposits AVAX into the contract
    event Deposit(address indexed user, uint amount);

    /// @notice Emitted when the cooldown period is updated
    event CooldownPeriodUpdated(uint oldCooldownPeriod, uint newCooldownPeriod);

    /// @notice Emitted when the redeem period is updated
    event RedeemPeriodUpdated(uint oldRedeemPeriod, uint newRedeemPeriod);

    /// @notice Emitted when the maximum pooled AVAX amount is changed
    event TotalPooledAvaxCapUpdated(uint oldTotalPooldAvaxCap, uint newTotalPooledAvaxCap);

    /// @notice Emitted when rewards are distributed into the pool
    event AccrueRewards(uint value);

    /// @notice Emitted when sAVAX minting is paused
    event MintingPaused(address user);

    /// @notice Emitted when sAVAX minting is resumed
    event MintingResumed(address user);

    constructor() initializer public {}

    /**
     * @notice Initialize the StakedAvax contract
     * @param _cooldownPeriod Time delay before shares can be burned for AVAX
     * @param _redeemPeriod AVAX redemption period after unlock cooldown has elapsed
     */
    function initialize(uint _cooldownPeriod, uint _redeemPeriod) initializer public {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

        cooldownPeriod = _cooldownPeriod;
        emit CooldownPeriodUpdated(0, _cooldownPeriod);

        redeemPeriod = _redeemPeriod;
        emit RedeemPeriodUpdated(0, _redeemPeriod);

        totalPooledAvaxCap = uint(-1);
        emit TotalPooledAvaxCapUpdated(0, totalPooledAvaxCap);
    }

    /**
     * @return The name of the token.
     */
    function name() public pure returns (string memory) {
        return "Staked AVAX";
    }

    /**
     * @return The symbol of the token.
     */
    function symbol() public pure returns (string memory) {
        return "sAVAX";
    }

    /**
     * @return The number of decimals for getting user representation of a token amount.
     */
    function decimals() public pure returns (uint8) {
        return 18;
    }

    /**
     * @return The amount of tokens in existence.
     */
    function totalSupply() public view override returns (uint) {
        return totalShares;
    }

    /**
     * @return The amount of sAVAX tokens owned by the `account`.
     */
    function balanceOf(address account) public view override returns (uint) {
        return shares[account];
    }

    /**
     * @notice Moves `amount` tokens from the caller's account to the `recipient` account.
     * Emits a `Transfer` event.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     * - the contract must not be paused.
     *
     * @return A boolean value indicating whether the operation succeeded.
     */
    function transfer(address recipient, uint amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);

        return true;
    }

    /**
     * @return The remaining number of tokens that `spender` is allowed to spend on behalf of `owner`
     * through `transferFrom`. This is zero by default.
     *
     * @dev This value changes when `approve` or `transferFrom` is called.
     */
    function allowance(address owner, address spender) public view override returns (uint) {
        return allowances[owner][spender];
    }

    /**
     * @notice Sets `amount` as the allowance of `spender` over the caller's tokens.
     * Emits an `Approval` event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - the contract must not be paused.
     *
     * @return A boolean value indicating whether the operation succeeded.
     */
    function approve(address spender, uint amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);

        return true;
    }

    /**
     * @notice Moves `amount` tokens from `sender` to `recipient` using the allowance mechanism. `amount`
     * is then deducted from the caller's allowance.
     *
     * @return A boolean value indicating whether the operation succeeded.
     *
     * Emits a `Transfer` event.
     * Emits an `Approval` event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero addresses.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for `sender`'s tokens of at least `amount`.
     * - the contract must not be paused.
     */
    function transferFrom(address sender, address recipient, uint amount) public override returns (bool) {
        uint currentAllowance = allowances[sender][msg.sender];
        require(currentAllowance >= amount, "TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE");

        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, currentAllowance.sub(amount));

        return true;
    }

    /**
     * @return The amount of shares that corresponds to `avaxAmount` protocol-controlled AVAX.
     */
    function getSharesByPooledAvax(uint avaxAmount) public view returns (uint) {
        if (totalPooledAvax == 0) {
            return 0;
        }

        uint shares = avaxAmount.mul(totalShares).div(totalPooledAvax);
        require(shares > 0, "Invalid share count");

        return shares;
    }

    /**
     * @return The amount of AVAX that corresponds to `shareAmount` token shares.
     */
    function getPooledAvaxByShares(uint shareAmount) public view returns (uint) {
        if (totalShares == 0) {
            return 0;
        }

        return shareAmount.mul(totalPooledAvax).div(totalShares);
    }

    /**
     * @notice Start unlocking cooldown period for `shareAmount` AVAX
     * @param shareAmount Amount of shares to unlock
     */
    function requestUnlock(uint shareAmount) external nonReentrant whenNotPaused {
        require(shareAmount > 0, "Invalid unlock amount");
        require(shareAmount <= shares[msg.sender], "Unlock amount too large");

        userSharesInCustody[msg.sender] = userSharesInCustody[msg.sender].add(shareAmount);
        _transfer(msg.sender, address(this), shareAmount);

        userUnlockRequests[msg.sender].push(UnlockRequest(
            block.timestamp,
            shareAmount
        ));

        emit UnlockRequested(msg.sender, shareAmount);
    }

    /**
     * @notice Get the number of active unlock requests by user
     * @param user User address
     */
    function getUnlockRequestCount(address user) external view returns (uint) {
        return userUnlockRequests[user].length;
    }

    /**
     * @notice Get a subsection of a user's unlock requests
     * @param user User account address
     * @param from List start index
     * @param to List end index
     */
    function getPaginatedUnlockRequests(address user, uint from, uint to)
        external
        view
        returns (
            UnlockRequest[] memory,
            uint[] memory
        )
    {
        require(from < userUnlockRequests[user].length, "From index out of bounds");
        require(from < to, "To index must be greater than from index");

        if (to > userUnlockRequests[user].length) {
            to = userUnlockRequests[user].length;
        }

        UnlockRequest[] memory paginatedUnlockRequests = new UnlockRequest[](to.sub(from));
        uint[] memory exchangeRates = new uint[](to.sub(from));

        for (uint i = 0; i < to.sub(from); i = i.add(1)) {
            paginatedUnlockRequests[i] = userUnlockRequests[user][from.add(i)];

            if (_isWithinRedemptionPeriod(paginatedUnlockRequests[i])) {
                (bool success, uint exchangeRate) = _getExchangeRateByUnlockTimestamp(paginatedUnlockRequests[i].startedAt);
                require(success, "Exchange rate not found");

                exchangeRates[i] = exchangeRate;
            }
        }

        return (paginatedUnlockRequests, exchangeRates);
    }

    /**
     * @notice Cancel all unlock requests that are pending the cooldown period to elapse.
     */
    function cancelPendingUnlockRequests() external nonReentrant {
        uint unlockIndex;
        while (unlockIndex < userUnlockRequests[msg.sender].length) {
            if (!_isWithinCooldownPeriod(userUnlockRequests[msg.sender][unlockIndex])) {
                unlockIndex = unlockIndex.add(1);
                continue;
            }

            _cancelUnlockRequest(unlockIndex);
        }
    }

    /**
     * @notice Cancel all unlock requests that are redeemable.
     */
    function cancelRedeemableUnlockRequests() external nonReentrant {
        uint unlockIndex;
        while (unlockIndex < userUnlockRequests[msg.sender].length) {
            if (!_isWithinRedemptionPeriod(userUnlockRequests[msg.sender][unlockIndex])) {
                unlockIndex = unlockIndex.add(1);
                continue;
            }

            _cancelUnlockRequest(unlockIndex);
        }
    }

    /**
     * @notice Cancel an unexpired unlock request
     * @param unlockIndex Index number of the cancelled unlock
     */
    function cancelUnlockRequest(uint unlockIndex) external nonReentrant {
        _cancelUnlockRequest(unlockIndex);
    }

    /**
     * @notice Redeem all redeemable AVAX from all unlocks
     */
    function redeem() external nonReentrant {
        uint unlockRequestCount = userUnlockRequests[msg.sender].length;
        uint i = 0;

        while (i < unlockRequestCount) {
            if (!_isWithinRedemptionPeriod(userUnlockRequests[msg.sender][i])) {
                i = i.add(1);
                continue;
            }

            _redeem(i);

            unlockRequestCount = unlockRequestCount.sub(1);
        }
    }

    /**
     * @notice Redeem AVAX after cooldown has finished
     * @param unlockIndex Index number of the redeemed unlock request
     */
    function redeem(uint unlockIndex) external nonReentrant {
        _redeem(unlockIndex);
    }

    /**
     * @notice Redeem all sAVAX held in custody for overdue unlock requests
     */
    function redeemOverdueShares() external nonReentrant whenNotPaused {
        uint totalOverdueShares = 0;

        uint unlockCount = userUnlockRequests[msg.sender].length;
        uint i = 0;
        while (i < unlockCount) {
            UnlockRequest memory unlockRequest = userUnlockRequests[msg.sender][i];

            if (!_isExpired(unlockRequest)) {
                i = i.add(1);
                continue;
            }

            totalOverdueShares = totalOverdueShares.add(unlockRequest.shareAmount);

            userUnlockRequests[msg.sender][i] = userUnlockRequests[msg.sender][userUnlockRequests[msg.sender].length.sub(1)];
            userUnlockRequests[msg.sender].pop();

            unlockCount = unlockCount.sub(1);
        }

        if (totalOverdueShares > 0) {
            userSharesInCustody[msg.sender] = userSharesInCustody[msg.sender].sub(totalOverdueShares);
            _transfer(address(this), msg.sender, totalOverdueShares);

            emit RedeemOverdueShares(msg.sender, totalOverdueShares);
        }
    }

    /**
     * @notice Redeem sAVAX held in custody for the given unlock request
     * @param unlockIndex Unlock request array index
     */
    function redeemOverdueShares(uint unlockIndex) external nonReentrant whenNotPaused {
        require(unlockIndex < userUnlockRequests[msg.sender].length, "Invalid unlock index");

        UnlockRequest memory unlockRequest = userUnlockRequests[msg.sender][unlockIndex];

        require(_isExpired(unlockRequest), "Unlock request is not expired");

        uint shareAmount = unlockRequest.shareAmount;
        userSharesInCustody[msg.sender] = userSharesInCustody[msg.sender].sub(shareAmount);

        userUnlockRequests[msg.sender][unlockIndex] = userUnlockRequests[msg.sender][userUnlockRequests[msg.sender].length - 1];
        userUnlockRequests[msg.sender].pop();

        _transfer(address(this), msg.sender, shareAmount);

        emit RedeemOverdueShares(msg.sender, shareAmount);
    }

    /**
     * @notice Process user deposit, mints liquid tokens and increase the pool buffer
     * @return Amount of sAVAX shares generated
     */
    function submit() public payable whenNotPaused returns (uint) {
        address sender = msg.sender;
        uint deposit = msg.value;

        require(deposit != 0, "ZERO_DEPOSIT");

        uint shareAmount = getSharesByPooledAvax(deposit);
        if (shareAmount == 0) {
            shareAmount = deposit;
        }

        _mintShares(sender, shareAmount);
        totalPooledAvax = totalPooledAvax.add(deposit);

        emit Transfer(address(0), sender, shareAmount);
        emit Submitted(sender, deposit, shareAmount);

        return shareAmount;
    }

    receive() external payable {
        submit();
    }


    /*********************************************************************************
     *                                                                               *
     *                             INTERNAL FUNCTIONS                                *
     *                                                                               *
     *********************************************************************************/


    /**
     * @notice Moves `amount` tokens from `sender` to `recipient`.
     * Emits a `Transfer` event.
     */
    function _transfer(address sender, address recipient, uint amount) internal {
        _transferShares(sender, recipient, amount);

        emit Transfer(sender, recipient, amount);
    }

    /**
     * @notice Sets `amount` as the allowance of `spender` over the `owner`s tokens.
     *
     * Emits an `Approval` event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     * - the contract must not be paused.
     */
    function _approve(address owner, address spender, uint amount) internal whenNotPaused {
        require(owner != address(0), "APPROVE_FROM_ZERO_ADDRESS");
        require(spender != address(0), "APPROVE_TO_ZERO_ADDRESS");

        allowances[owner][spender] = amount;

        emit Approval(owner, spender, amount);
    }

    /**
     * @notice Moves `shareAmount` shares from `sender` to `recipient`.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must hold at least `shareAmount` shares.
     * - the contract must not be paused.
     */
    function _transferShares(address sender, address recipient, uint shareAmount) internal whenNotPaused {
        require(sender != address(0), "TRANSFER_FROM_THE_ZERO_ADDRESS");
        require(recipient != address(0), "TRANSFER_TO_THE_ZERO_ADDRESS");
        require(sender != recipient, "TRANSFER_TO_SELF");

        uint currentSenderShares = shares[sender];
        require(shareAmount <= currentSenderShares, "TRANSFER_AMOUNT_EXCEEDS_BALANCE");
        require(shareAmount > 0, "TRANSFER_ZERO_VALUE");

        if (shares[recipient] == 0) {
            stakerCount = stakerCount.add(1);
        }

        shares[sender] = currentSenderShares.sub(shareAmount);
        shares[recipient] = shares[recipient].add(shareAmount);

        if (shares[sender] == 0) {
            stakerCount = stakerCount.sub(1);
        }
    }

    /**
     * @notice Creates `shareAmount` shares and assigns them to `recipient`, increasing the total amount of shares.
     * @dev This doesn't increase the token total supply.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address
     * - the contract must not be paused
     * - minting must not be paused
     * - total pooled AVAX cap must not be exceeded
     */
    function _mintShares(address recipient, uint shareAmount) internal whenNotPaused returns (uint) {
        require(!mintingPaused, "Minting paused");
        require(recipient != address(0), "MINT_TO_THE_ZERO_ADDRESS");
        require(shareAmount > 0, "MINT_ZERO_VALUE");

        uint avaxAmount = getPooledAvaxByShares(shareAmount);
        require(totalPooledAvax.add(avaxAmount) <= totalPooledAvaxCap, "TOTAL_POOLED_AVAX_CAP_EXCEEDED");

        if (shares[recipient] == 0) {
            stakerCount = stakerCount.add(1);
        }

        totalShares = totalShares.add(shareAmount);
        shares[recipient] = shares[recipient].add(shareAmount);

        return totalShares;
    }

    /**
     * @notice Destroys `shareAmount` shares from `account`'s holdings, decreasing the total amount of shares.
     * @dev This doesn't decrease the token total supply.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must hold at least `shareAmount` shares.
     * - the contract must not be paused.
     */
    function _burnShares(address account, uint shareAmount) internal whenNotPaused returns (uint) {
        require(account != address(0), "BURN_FROM_THE_ZERO_ADDRESS");
        require(shareAmount > 0, "BURN_ZERO_VALUE");

        uint accountShares = shares[account];
        require(shareAmount <= accountShares, "BURN_AMOUNT_EXCEEDS_BALANCE");

        totalShares = totalShares.sub(shareAmount);
        shares[account] = accountShares.sub(shareAmount);

        if (shares[account] == 0) {
            stakerCount = stakerCount.sub(1);
        }

        return totalShares;
    }

    /**
     * @notice Checks if the unlock request is within its cooldown period
     * @param unlockRequest Unlock request
     */
    function _isWithinCooldownPeriod(UnlockRequest memory unlockRequest) internal view returns (bool) {
        return unlockRequest.startedAt.add(cooldownPeriod) >= block.timestamp;
    }

    /**
     * @notice Checks if the unlock request is within its redemption period
     * @param unlockRequest Unlock request
     */
    function _isWithinRedemptionPeriod(UnlockRequest memory unlockRequest) internal view returns (bool) {
        return !_isWithinCooldownPeriod(unlockRequest)
            && unlockRequest.startedAt.add(cooldownPeriod).add(redeemPeriod) >= block.timestamp;
    }

    /**
     * @notice Checks if the unlock request has expired
     * @param unlockRequest Unlock request
     */
    function _isExpired(UnlockRequest memory unlockRequest) internal view returns (bool) {
        return unlockRequest.startedAt.add(cooldownPeriod).add(redeemPeriod) < block.timestamp;
    }

    /**
     * @notice Cancel an unexpired unlock request
     * @param unlockIndex Index number of the cancelled unlock
     */
    function _cancelUnlockRequest(uint unlockIndex) internal whenNotPaused {
        require(unlockIndex < userUnlockRequests[msg.sender].length, "Invalid index");

        UnlockRequest memory unlockRequest = userUnlockRequests[msg.sender][unlockIndex];

        require(!_isExpired(unlockRequest), "Unlock request is expired");

        uint shareAmount = unlockRequest.shareAmount;
        uint unlockRequestedAt = unlockRequest.startedAt;

        if (unlockIndex != userUnlockRequests[msg.sender].length - 1) {
            userUnlockRequests[msg.sender][unlockIndex] = userUnlockRequests[msg.sender][userUnlockRequests[msg.sender].length - 1];
        }

        userUnlockRequests[msg.sender].pop();

        userSharesInCustody[msg.sender] = userSharesInCustody[msg.sender].sub(shareAmount);
        _transfer(address(this), msg.sender, shareAmount);

        emit UnlockCancelled(msg.sender, unlockRequestedAt, shareAmount);
    }

    /**
     * @notice Redeem AVAX after cooldown has finished
     * @param unlockRequestIndex Index number of the redeemed unlock request
     */
    function _redeem(uint unlockRequestIndex) internal whenNotPaused {
        require(unlockRequestIndex < userUnlockRequests[msg.sender].length, "Invalid unlock request index");

        UnlockRequest memory unlockRequest = userUnlockRequests[msg.sender][unlockRequestIndex];

        require(_isWithinRedemptionPeriod(unlockRequest), "Unlock request is not redeemable");

        (bool success, uint exchangeRate) = _getExchangeRateByUnlockTimestamp(unlockRequest.startedAt);
        require(success, "Exchange rate not found");

        uint shareAmount = unlockRequest.shareAmount;
        uint startedAt = unlockRequest.startedAt;
        uint avaxAmount = exchangeRate.mul(shareAmount).div(1e18);

        require(avaxAmount >= shareAmount, "Invalid exchange rate");

        userSharesInCustody[msg.sender] = userSharesInCustody[msg.sender].sub(shareAmount);
        _burnShares(address(this), shareAmount);

        totalPooledAvax = totalPooledAvax.sub(avaxAmount);

        userUnlockRequests[msg.sender][unlockRequestIndex] = userUnlockRequests[msg.sender][userUnlockRequests[msg.sender].length.sub(1)];
        userUnlockRequests[msg.sender].pop();

        (success, ) = msg.sender.call{ value: avaxAmount }("");
        require(success, "AVAX transfer failed");

        emit Redeem(msg.sender, startedAt, shareAmount, avaxAmount);
    }

    /**
     * @notice Get the earliest exchange rate closest to the unlock timestamp
     * @param unlockTimestamp Unlock request timestamp
     * @return (success, exchange rate)
     */
    function _getExchangeRateByUnlockTimestamp(uint unlockTimestamp) internal view returns (bool, uint) {
        if (historicalExchangeRateTimestamps.length == 0) {
            return (false, 0);
        }

        uint low = 0;
        uint mid;
        uint high = historicalExchangeRateTimestamps.length - 1;

        uint unlockClaimableAtTimestamp = unlockTimestamp.add(cooldownPeriod);

        while (low <= high) {
            mid = high.add(low).div(2);

            if (historicalExchangeRateTimestamps[mid] <= unlockClaimableAtTimestamp) {
                if (mid.add(1) == historicalExchangeRateTimestamps.length ||
                    historicalExchangeRateTimestamps[mid.add(1)] > unlockClaimableAtTimestamp) {
                    return (true, historicalExchangeRatesByTimestamp[historicalExchangeRateTimestamps[mid]]);
                }

                low = mid.add(1);
            } else if (mid == 0) {
                return (true, 1e18);
            } else {
                high = mid.sub(1);
            }
        }

        return (false, 0);
    }

    /**
     * @notice Remove exchange rate entries older than `redeemPeriod`
     */
    function _dropExpiredExchangeRateEntries() internal {
        if (historicalExchangeRateTimestamps.length == 0) {
            return;
        }

        uint shiftCount = 0;
        uint expirationThreshold = block.timestamp.sub(redeemPeriod).sub(172800);

        while (shiftCount < historicalExchangeRateTimestamps.length &&
            historicalExchangeRateTimestamps[shiftCount] < expirationThreshold) {
            shiftCount = shiftCount.add(1);
        }

        if (shiftCount == 0) {
            return;
        }

        for (uint i = 0; i < historicalExchangeRateTimestamps.length.sub(shiftCount); i = i.add(1)) {
            historicalExchangeRateTimestamps[i] = historicalExchangeRateTimestamps[i.add(shiftCount)];
        }

        for (uint i = 1; i <= shiftCount; i = i.add(1)) {
            historicalExchangeRateTimestamps.pop();
        }
    }

    /*********************************************************************************
     *                                                                               *
     *                            ADMIN-ONLY FUNCTIONS                               *
     *                                                                               *
     *********************************************************************************/

    /**
     * @notice Accrue staking rewards to the pool
     * @param amount Amount of rewards accrued to the pool
     */
    function accrueRewards(uint amount) external nonReentrant {
        require(hasRole(ROLE_ACCRUE_REWARDS, msg.sender), "ROLE_ACCRUE_REWARDS");

        totalPooledAvax = totalPooledAvax.add(amount);

        _dropExpiredExchangeRateEntries();
        historicalExchangeRatesByTimestamp[block.timestamp] = getPooledAvaxByShares(1e18);
        historicalExchangeRateTimestamps.push(block.timestamp);

        emit AccrueRewards(amount);
    }

    /**
     * @notice Withdraw AVAX from the contract for delegation
     * @param amount Amount of AVAX to withdraw
     */
    function withdraw(uint amount) external nonReentrant {
        require(hasRole(ROLE_WITHDRAW, msg.sender), "ROLE_WITHDRAW");

        (bool success, ) = msg.sender.call{ value: amount }("");
        require(success, "AVAX transfer failed");

        emit Withdraw(msg.sender, amount);
    }

    /**
     * @notice Deposit AVAX into the contract without minting sAVAX
     */
    function deposit() external payable {
        require(hasRole(ROLE_DEPOSIT, msg.sender), "ROLE_DEPOSIT");
        require(msg.value > 0, "Zero value");

        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Update the cooldown period
     * @param newCooldownPeriod New cooldown period
     */
    function setCooldownPeriod(uint newCooldownPeriod) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "DEFAULT_ADMIN_ROLE");

        uint oldCooldownPeriod = cooldownPeriod;
        cooldownPeriod = newCooldownPeriod;

        emit CooldownPeriodUpdated(oldCooldownPeriod, cooldownPeriod);
    }

    /**
     * @notice Update the redeem period
     * @param newRedeemPeriod New redeem period
     */
    function setRedeemPeriod(uint newRedeemPeriod) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "DEFAULT_ADMIN_ROLE");

        uint oldRedeemPeriod = redeemPeriod;
        redeemPeriod = newRedeemPeriod;

        emit RedeemPeriodUpdated(oldRedeemPeriod, redeemPeriod);
    }

    /**
     * @notice Set a upper limit for the total pooled AVAX amount
     * @param newTotalPooledAvaxCap The pool cap
     */
    function setTotalPooledAvaxCap(uint newTotalPooledAvaxCap) external {
        require(hasRole(ROLE_SET_TOTAL_POOLED_AVAX_CAP, msg.sender), "ROLE_SET_TOTAL_POOLED_AVAX_CAP");

        uint oldTotalPooledAvaxCap = totalPooledAvaxCap;
        totalPooledAvaxCap = newTotalPooledAvaxCap;

        emit TotalPooledAvaxCapUpdated(oldTotalPooledAvaxCap, newTotalPooledAvaxCap);
    }

    /**
     * @notice Stop pool routine operations
     */
    function pause() external {
        require(hasRole(ROLE_PAUSE, msg.sender), "ROLE_PAUSE");

        _pause();
    }

    /**
     * @notice Resume pool routine operations
     */
    function resume() external {
        require(hasRole(ROLE_RESUME, msg.sender), "ROLE_RESUME");

        _unpause();
    }

    /**
     * @notice Stop minting
     */
    function pauseMinting() external {
        require(hasRole(ROLE_PAUSE_MINTING, msg.sender), "ROLE_PAUSE_MINTING");
        require(!mintingPaused, "Minting is already paused");

        mintingPaused = true;
        emit MintingPaused(msg.sender);
    }

    /**
     * @notice Resume minting
     */
    function resumeMinting() external {
        require(hasRole(ROLE_RESUME_MINTING, msg.sender), "ROLE_RESUME_MINTING");
        require(mintingPaused, "Minting is not paused");

        mintingPaused = false;
        emit MintingResumed(msg.sender);
    }
}

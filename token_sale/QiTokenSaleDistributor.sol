pragma solidity 0.6.12;

import "./ReentrancyGuard.sol";
import "./EIP20Interface.sol";
import "./SafeMath.sol";
import "./QiTokenSaleDistributorStorage.sol";
import "./QiTokenSaleDistributorProxy.sol";


contract QiTokenSaleDistributor is ReentrancyGuard, QiTokenSaleDistributorStorage {
    using SafeMath for uint256;

    event Claim(address recipient, uint amount);

    constructor() public {
        admin = msg.sender;
    }


    /********************************************************
     *                                                      *
     *                   PUBLIC FUNCTIONS                   *
     *                                                      *
     ********************************************************/

    /*
     * Claim all available tokens for the invoking user.
     */
    function claim() public nonReentrant {
        uint availableTokensToClaim = 0;
        for (uint round = 0; round < completedPurchaseRounds[msg.sender]; round += 1) {
            uint claimableRoundTokens = _getClaimableTokenAmountPerRound(msg.sender, round);
            availableTokensToClaim = availableTokensToClaim.add(claimableRoundTokens);
            claimedTokens[msg.sender][round] = claimedTokens[msg.sender][round].add(claimableRoundTokens);
        }

        require(availableTokensToClaim > 0, "No available tokens to claim");

        EIP20Interface qi = EIP20Interface(qiContractAddress);
        qi.transfer(msg.sender, availableTokensToClaim);

        emit Claim(msg.sender, availableTokensToClaim);
    }

    /**
     * Get the amount of QI tokens available for the caller to claim.
     *
     * @return Number of QI tokens available for claiming
     */
    function getClaimableTokenAmount() public view returns (uint) {
        return _getClaimableTokenAmount(msg.sender);
    }

    /**
     * Get the amount of QI tokens available for the caller to claim from
     * the given purchase round.
     *
     * @param round Purchase round number
     * @return Number of QI tokens available for claiming from the given round
     */
    function getRoundClaimableTokenAmount(uint round) public view returns (uint) {
        return _getClaimableTokenAmountPerRound(msg.sender, round);
    }

    /**
     * Get the total number of claimed tokens by the user.
     *
     * @return Number of claimed QI tokens
     */
    function getClaimedTokenAmount() public view returns (uint) {
        uint claimedTokenAmount = 0;
        for (uint round = 0; round < completedPurchaseRounds[msg.sender]; round += 1) {
            claimedTokenAmount = claimedTokenAmount.add(claimedTokens[msg.sender][round]);
        }

        return claimedTokenAmount;
    }

    /**
     * Get the number of claimed tokens in a specific round by the user.
     *
     * @param round Purchase round number
     * @return Number of claimed QI tokens
     */
    function getRoundClaimedTokenAmount(uint round) public view returns (uint) {
        return claimedTokens[msg.sender][round];
    }

    /********************************************************
     *                                                      *
     *               ADMIN-ONLY FUNCTIONS                   *
     *                                                      *
     ********************************************************/

    /**
     * Set the QI token contract address.
     *
     * @param newQiContractAddress New address of the QI token contract
     */
    function setQiContractAddress(address newQiContractAddress) public adminOnly {
        qiContractAddress = newQiContractAddress;
    }

    /**
     * Set the amount of purchased QI tokens per user.
     *
     * @param recipients QI token recipients
     * @param rounds Purchase round number
     * @param tokenInitialReleasePercentages Initial token release percentages
     * @param tokenReleasePeriods Number of token release periods
     * @param amounts Purchased token amounts
     */
    function setPurchasedTokensByUser(
        address[] memory recipients,
        uint[] memory rounds,
        uint[] memory tokenInitialReleasePercentages,
        uint[] memory tokenReleasePeriods,
        uint[] memory amounts
    )
        public
        adminOrDataAdminOnly
    {
        require(recipients.length == rounds.length);
        require(recipients.length == tokenInitialReleasePercentages.length);
        require(recipients.length == tokenReleasePeriods.length);
        require(recipients.length == amounts.length);

        for (uint i = 0; i < recipients.length; i += 1) {
            address recipient = recipients[i];

            require(tokenInitialReleasePercentages[i] <= 100, "Invalid percentage");
            require(rounds[i] == completedPurchaseRounds[recipient], "Invalid round number");

            initialReleasePercentages[recipient][rounds[i]] = tokenInitialReleasePercentages[i].mul(1e18);
            releasePeriods[recipient][rounds[i]] = tokenReleasePeriods[i];
            purchasedTokens[recipient][rounds[i]] = amounts[i];
            completedPurchaseRounds[recipient] = rounds[i] + 1;
            claimedTokens[recipient][rounds[i]] = tokenInitialReleasePercentages[i].mul(1e18).mul(amounts[i]).div(100e18);
        }
    }

    /**
     * Reset all data for the given addresses.
     *
     * @param recipients Addresses whose data to reset
     */
    function resetPurchasedTokensByUser(address[] memory recipients) public adminOrDataAdminOnly {
        for (uint i = 0; i < recipients.length; i += 1) {
            address recipient = recipients[i];

            for (uint round = 0; round < completedPurchaseRounds[recipient]; round += 1) {
                initialReleasePercentages[recipient][round] = 0;
                releasePeriods[recipient][round] = 0;
                purchasedTokens[recipient][round] = 0;
                claimedTokens[recipient][round] = 0;
            }

            completedPurchaseRounds[recipient] = 0;
        }
    }

    /**
     * Withdraw deposited QI tokens from the contract.
     *
     * @param amount QI amount to withdraw from the contract balance
     */
    function withdrawQi(uint amount) public adminOnly {
        EIP20Interface qi = EIP20Interface(qiContractAddress);
        qi.transfer(msg.sender, amount);
    }

    /**
     * Accept this contract as the implementation for a proxy.
     *
     * @param proxy QiTokenSaleDistributorProxy
     */
    function becomeImplementation(QiTokenSaleDistributorProxy proxy) external {
        require(msg.sender == proxy.admin(), "Only proxy admin can change the implementation");
        proxy.acceptPendingImplementation();
    }

    /**
     * Set the data admin.
     *
     * @param newDataAdmin New data admin address
     */
    function setDataAdmin(address newDataAdmin) public adminOnly {
        dataAdmin = newDataAdmin;
    }


    /********************************************************
     *                                                      *
     *                  INTERNAL FUNCTIONS                  *
     *                                                      *
     ********************************************************/

    /**
     * Get the number of claimable QI tokens for a user at the time of calling.
     *
     * @param recipient Claiming user
     * @return Number of QI tokens
     */
    function _getClaimableTokenAmount(address recipient) internal view returns (uint) {
        if (completedPurchaseRounds[recipient] == 0) {
            return 0;
        }

        uint remainingClaimableTokensToDate = 0;
        for (uint round = 0; round < completedPurchaseRounds[recipient]; round += 1) {
            uint remainingRoundClaimableTokensToDate = _getClaimableTokenAmountPerRound(recipient, round);
            remainingClaimableTokensToDate = remainingClaimableTokensToDate.add(remainingRoundClaimableTokensToDate);
        }

        return remainingClaimableTokensToDate;
    }

    /**
     * Get the number of claimable QI tokens from a specific purchase round
     * for a user at the time of calling.
     *
     * @param recipient Recipient address
     * @param round Purchase round number
     * @return Available tokens to claim from the round
     */
    function _getClaimableTokenAmountPerRound(address recipient, uint round) internal view returns (uint) {
        require(round < completedPurchaseRounds[recipient], "Invalid round");

        if (completedPurchaseRounds[recipient] == 0) {
            return 0;
        }

        uint initialClaimableTokens = initialReleasePercentages[recipient][round].mul(purchasedTokens[recipient][round]).div(100e18);

        uint elapsedSecondsSinceEpoch = block.timestamp.sub(vestingScheduleEpoch);
        // Number of elapsed release periods after the initial release
        uint elapsedVestingReleasePeriods = elapsedSecondsSinceEpoch.div(releasePeriodLength);

        uint claimableTokensToDate = 0;
        if (elapsedVestingReleasePeriods.add(1) >= releasePeriods[recipient][round]) {
            claimableTokensToDate = purchasedTokens[recipient][round];
        } else {
            uint claimableTokensPerPeriod = purchasedTokens[recipient][round].sub(initialClaimableTokens).div(releasePeriods[recipient][round].sub(1));
            claimableTokensToDate = claimableTokensPerPeriod.mul(elapsedVestingReleasePeriods).add(initialClaimableTokens);
            if (claimableTokensToDate > purchasedTokens[recipient][round]) {
                claimableTokensToDate = purchasedTokens[recipient][round];
            }
        }

        uint remainingClaimableTokensToDate = claimableTokensToDate.sub(claimedTokens[recipient][round]);

        return remainingClaimableTokensToDate;
    }


    /********************************************************
     *                                                      *
     *                      MODIFIERS                       *
     *                                                      *
     ********************************************************/

    modifier adminOnly {
        require(msg.sender == admin, "admin only");
        _;
    }

    modifier adminOrDataAdminOnly {
        require(msg.sender == admin || (dataAdmin != address(0) && msg.sender == dataAdmin), "admin only");
        _;
    }
}

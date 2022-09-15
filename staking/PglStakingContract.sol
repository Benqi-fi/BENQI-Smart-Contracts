pragma solidity 0.5.17;

import "../OpenZeppelin/ReentrancyGuard.sol";
import "../EIP20Interface.sol";
import "../SafeMath.sol";
import "./PglStakingContractStorage.sol";
import "./PglStakingContractProxy.sol";


contract PglStakingContract is ReentrancyGuard, PglStakingContractStorage {
    using SafeMath for uint256;

    constructor() public {
        admin = msg.sender;
    }


    /********************************************************
     *                                                      *
     *                   PUBLIC FUNCTIONS                   *
     *                                                      *
     ********************************************************/

    /**
     * Deposit Pangolin QI-AVAX liquidity provider tokens into the staking contract.
     *
     * @param pglAmount The amount of PGL tokens to deposit
     */
    function deposit(uint pglAmount) external nonReentrant {
        require(pglTokenAddress != address(0), "PGL Token address can not be zero");

        EIP20Interface pglToken = EIP20Interface(pglTokenAddress);
        uint contractBalance = pglToken.balanceOf(address(this));
        pglToken.transferFrom(msg.sender, address(this), pglAmount);
        uint depositedAmount = pglToken.balanceOf(address(this)).sub(contractBalance);

        require(depositedAmount > 0, "Zero deposit");

        distributeReward(msg.sender);

        totalSupplies = totalSupplies.add(depositedAmount);
        supplyAmount[msg.sender] = supplyAmount[msg.sender].add(depositedAmount);
    }

    /**
     * Redeem deposited PGL tokens from the contract.
     *
     * @param pglAmount Redeem amount
     */
    function redeem(uint pglAmount) external nonReentrant {
        require(pglTokenAddress != address(0), "PGL Token address can not be zero");
        require(pglAmount <= supplyAmount[msg.sender], "Too large withdrawal");

        distributeReward(msg.sender);

        supplyAmount[msg.sender] = supplyAmount[msg.sender].sub(pglAmount);
        totalSupplies = totalSupplies.sub(pglAmount);

        EIP20Interface pglToken = EIP20Interface(pglTokenAddress);
        pglToken.transfer(msg.sender, pglAmount);
    }

    /**
     * Claim pending rewards from the staking contract by transferring them
     * to the requester.
     */
    function claimRewards() external nonReentrant {
        distributeReward(msg.sender);

        uint amount = accruedReward[msg.sender][REWARD_QI];
        claimErc20(REWARD_QI, msg.sender, amount);
    }

    /**
     * Get the current amount of available rewards for claiming.
     *
     * @param rewardToken Reward token whose claimable balance to query
     * @return Balance of claimable reward tokens
     */
    function getClaimableRewards(uint rewardToken) external view returns(uint) {
        require(rewardToken <= nofStakingRewards, "Invalid reward token");

        // Static reward value for AVAX due to erroneously emitted AVAX
        if (rewardToken == REWARD_AVAX) {
            return 0;
        }

        uint rewardIndexDelta = rewardIndex[rewardToken].sub(supplierRewardIndex[msg.sender][rewardToken]);
        uint claimableReward = rewardIndexDelta.mul(supplyAmount[msg.sender]).div(1e36).add(accruedReward[msg.sender][rewardToken]);

        return claimableReward;
    }

    /**
     * Fallback function to accept AVAX deposits.
     */
    function () external payable {}


    /********************************************************
     *                                                      *
     *               ADMIN-ONLY FUNCTIONS                   *
     *                                                      *
     ********************************************************/

    /**
     * Set reward distribution speed.
     *
     * @param rewardToken Reward token speed to change
     * @param speed New reward speed
     */
    function setRewardSpeed(uint rewardToken, uint speed) external adminOnly {
        if (accrualBlockTimestamp != 0) {
            accrueReward();
        }

        rewardSpeeds[rewardToken] = speed;
    }

    /**
     * Set ERC20 reward token contract address.
     *
     * @param rewardToken Reward token address to set
     * @param rewardTokenAddress New contract address
     */
    function setRewardTokenAddress(uint rewardToken, address rewardTokenAddress) external adminOnly {
        require(rewardToken != REWARD_AVAX, "Cannot set AVAX address");
        rewardTokenAddresses[rewardToken] = rewardTokenAddress;
    }

    /**
     * Set QI-AVAX PGL token contract address.
     *
     * @param newPglTokenAddress New QI-AVAX PGL token contract address
     */
    function setPglTokenAddress(address newPglTokenAddress) external adminOnly {
        pglTokenAddress = newPglTokenAddress;
    }

    /**
     * Accept this contract as the implementation for a proxy.
     *
     * @param proxy PglStakingContractProxy
     */
    function becomeImplementation(PglStakingContractProxy proxy) external {
        require(msg.sender == proxy.admin(), "Only proxy admin can change the implementation");
        proxy.acceptPendingImplementation();
    }


    /********************************************************
     *                                                      *
     *                  INTERNAL FUNCTIONS                  *
     *                                                      *
     ********************************************************/

    /**
     * Update reward accrual state.
     *
     * @dev accrueReward() must be called every time the token balances
     *      or reward speeds change
     */
    function accrueReward() internal {
        uint blockTimestampDelta = block.timestamp.sub(accrualBlockTimestamp);
        accrualBlockTimestamp = block.timestamp;

        if (blockTimestampDelta == 0 || totalSupplies == 0) {
            return;
        }

        for (uint i = 0; i < nofStakingRewards; i += 1) {
            uint rewardSpeed = rewardSpeeds[i];
            if (rewardSpeed == 0) {
                continue;
            }

            uint accrued = rewardSpeeds[i].mul(blockTimestampDelta);
            uint accruedPerPGL = accrued.mul(1e36).div(totalSupplies);

            rewardIndex[i] = rewardIndex[i].add(accruedPerPGL);
        }
    }

    /**
     * Calculate accrued rewards for a single account based on the reward indexes.
     *
     * @param recipient Account for which to calculate accrued rewards
     */
    function distributeReward(address recipient) internal {
        accrueReward();

        for (uint i = 0; i < nofStakingRewards; i += 1) {
            uint rewardIndexDelta = rewardIndex[i].sub(supplierRewardIndex[recipient][i]);
            uint accruedAmount = rewardIndexDelta.mul(supplyAmount[recipient]).div(1e36);
            accruedReward[recipient][i] = accruedReward[recipient][i].add(accruedAmount);
            supplierRewardIndex[recipient][i] = rewardIndex[i];
        }
    }

    /**
     * Transfer AVAX rewards from the contract to the reward recipient.
     *
     * @param recipient Address, whose AVAX rewards are claimed
     * @param amount The amount of claimed AVAX
     */
    function claimAvax(address payable recipient, uint amount) internal {
        require(accruedReward[recipient][REWARD_AVAX] <= amount, "Not enough accrued rewards");

        accruedReward[recipient][REWARD_AVAX] = accruedReward[recipient][REWARD_AVAX].sub(amount);
        recipient.transfer(amount);
    }

    /**
     * Transfer ERC20 rewards from the contract to the reward recipient.
     *
     * @param rewardToken ERC20 reward token which is claimed
     * @param recipient Address, whose rewards are claimed
     * @param amount The amount of claimed reward
     */
    function claimErc20(uint rewardToken, address recipient, uint amount) internal {
        require(rewardToken != REWARD_AVAX, "Cannot use claimErc20 for AVAX");
        require(accruedReward[recipient][rewardToken] <= amount, "Not enough accrued rewards");
        require(rewardTokenAddresses[rewardToken] != address(0), "reward token address can not be zero");

        EIP20Interface token = EIP20Interface(rewardTokenAddresses[rewardToken]);
        accruedReward[recipient][rewardToken] = accruedReward[recipient][rewardToken].sub(amount);
        token.transfer(recipient, amount);
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
}

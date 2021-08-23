pragma solidity 0.5.17;

import "./PglStakingContractProxyStorage.sol";


contract PglStakingContractStorage is PglStakingContractProxyStorage {
    uint constant nofStakingRewards = 2;
    uint constant REWARD_AVAX = 0;
    uint constant REWARD_QI = 1;

    // QI-AVAX PGL token contract address
    address public pglTokenAddress;

    // Addresses of the ERC20 reward tokens
    mapping(uint => address) public rewardTokenAddresses;

    // Reward accrual speeds per reward token as tokens per second
    mapping(uint => uint) public rewardSpeeds;

    // Unclaimed staking rewards per user and token
    mapping(address => mapping(uint => uint)) public accruedReward;

    // Supplied PGL tokens per user
    mapping(address => uint) public supplyAmount;

    // Sum of all supplied PGL tokens
    uint public totalSupplies;

    /*
     * rewardIndex keeps track of the total amount of rewards to be distributed for
     * each supplied unit of PGL tokens. When used together with supplierIndex,
     * the total amount of rewards to be paid out to individual users can be calculated
     * when the user claims their rewards.
     *
     * Consider the following:
     *
     * At contract deployment, the contract has a zero PGL balance. Immediately, a new
     * user, User A, deposits 1000 PGL tokens, thus increasing the total supply to
     * 1000 PGL. After 60 seconds, a second user, User B, deposits an additional 500 PGL,
     * increasing the total supplied amount to 1500 PGL.
     *
     * Because all balance-changing contract calls, as well as those changing the reward
     * speeds, must invoke the accrueRewards function, these deposit calls trigger the
     * function too. The accrueRewards function considers the reward speed (denoted in
     * reward tokens per second), the reward and supplier reward indexes, and the supply
     * balance to calculate the accrued rewards.
     *
     * When User A deposits their tokens, rewards are yet to be accrued due to previous
     * inactivity; the elapsed time since the previous, non-existent, reward-accruing
     * contract call is zero, thus having a reward accrual period of zero. The block
     * time of the deposit transaction is saved in the contract to indicate last
     * activity time.
     *
     * When User B deposits their tokens, 60 seconds has elapsed since the previous
     * call to the accrueRewards function, indicated by the difference of the current
     * block time and the last activity time. In other words, up till the time of
     * User B's deposit, the contract has had a 60 second accrual period for the total
     * amount of 1000 PGL tokens at the set reward speed. Assuming a reward speed of
     * 5 tokens per second (denoted 5 T/s), the accrueRewards function calculates the
     * accrued reward per supplied unit of PGL tokens for the elapsed time period.
     * This works out to ((5 T/s) / 1000 PGL) * 60 s = 0.3 T/PGL during the 60 second
     * period. At this point, the global reward index variable is updated, increasing
     * its value by 0.3 T/PGL, and the reward accrual block timestamp,
     * initialised in the previous step, is updated.
     *
     * After 90 seconds of the contract deployment, User A decides to claim their accrued
     * rewards. Claiming affects token balances, thus requiring an invocation of the
     * accrueRewards function. This time, the accrual period is 30 seconds (90 s - 60 s),
     * for which the reward accrued per unit of PGL is ((5 T/s) / 1500 PGL) * 30 s = 0.1 T/PGL.
     * The reward index is updated to 0.4 T/PGL (0.3 T/PGL + 0.1 T/PGL) and the reward
     * accrual block timestamp is set to the current block time.
     *
     * After the reward accrual, User A's rewards are claimed by transferring the correct
     * amount of T tokens from the contract to User A. Because User A has not claimed any
     * rewards yet, their supplier index is zero, the initial value determined by the
     * global reward index at the time of the user's first deposit. The amount of accrued
     * rewards is determined by the difference between the global reward index and the
     * user's own supplier index; essentially, this value represents the amount of
     * T tokens that have been accrued per supplied PGL during the time since the user's
     * last claim. User A has a supply balance of 1000 PGL, thus having an unclaimed
     * token amount of (0.4 T/PGL - 0 T/PGL) * 1000 PGL = 400 T. This amount is
     * transferred to User A, and their supplier index is set to the current global reward
     * index to indicate that all previous rewards have been accrued.
     *
     * If User B was to claim their rewards at the same time, the calculation would take
     * the form of (0.4 T/PGL - 0.3 T/PGL) * 500 PGL = 50 T. As expected, the total amount
     * of accrued reward (5 T/s * 90 s = 450 T) equals to the sum of the rewards paid
     * out to both User A and User B (400 T + 50 T = 450 T).
     *
     * This method of reward accrual is used to minimise the contract call complexity.
     * If a global mapping of users to their accrued rewards was implemented instead of
     * the index calculations, each function call invoking the accrueRewards function
     * would become immensely more expensive due to having to update the rewards for each
     * user. In contrast, the index approach allows the update of only a single user
     * while still keeping track of the other's rewards.
     *
     * Because rewards can be paid in multiple assets, reward indexes, reward supplier
     * indexes, and reward speeds depend on the StakingReward token.
     */
    mapping(uint => uint) public rewardIndex;
    mapping(address => mapping(uint => uint)) public supplierRewardIndex;
    uint public accrualBlockTimestamp;
}

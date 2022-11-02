// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./VeERC20Upgradeable.sol";
import "./libraries/Math.sol";
import "./interfaces/IVeQi.sol";

/// @title VeQi
/// @notice Staking contract for QI
contract VeQi is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    VeERC20Upgradeable,
    IVeQi
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct UserInfo {
        uint256 amount; // qi staked by user
        uint256 lastRelease; // time of last veQi claim or first deposit if user has not claimed yet
    }

    /// @notice user info mapping
    mapping(address => UserInfo) public users;

    /// @notice list of user addresses
    address[] public userList;
    mapping(address => uint256) public userListIndex;

    /// @notice the qi token
    IERC20Upgradeable public qi;

    /// @notice max veQi to staked qi ratio
    /// Note if user has 10 qi staked, they can only have a max of 10 * maxCap veQi in balance
    uint256 public maxCap;

    /// @notice the rate of veQi generated per second, per qi staked
    uint256 public generationRate;

    /// @notice events describing staking, unstaking and claiming
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event MaxCapUpdated(uint256 maxCap);
    event GenerateRateUpdated(uint256 generationRate);

    function initialize(IERC20Upgradeable _qi, uint256 _generationRate) external initializer {
        require(address(_qi) != address(0), "zero address");
        require(_generationRate > 0, "generation rate cannot be zero");

        // Initialize veQI
        __ERC20_init("Vote-escrowed BENQI", "veQI");
        __Ownable_init();
        __ReentrancyGuard_init_unchained();
        __Pausable_init_unchained();

        // set generationRate (veQi per sec per qi staked)
        generationRate = _generationRate;

        // set maxCap
        maxCap = 100;

        // set qi
        qi = _qi;
    }

    /**
     * @dev pause pool, restricting certain operations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev unpause pool, enabling certain operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice sets maxCap
    /// @param _maxCap the new max ratio
    function setMaxCap(uint256 _maxCap) external onlyOwner {
        require(_maxCap > 0, "max cap cannot be zero");
        maxCap = _maxCap;

        emit MaxCapUpdated(_maxCap);
    }

    /// @notice sets generation rate
    /// @param _generationRate the new max ratio
    function setGenerationRate(uint256 _generationRate) external onlyOwner {
        require(_generationRate > 0, "generation rate cannot be zero");
        generationRate = _generationRate;

        emit GenerateRateUpdated(_generationRate);
    }

    /// @notice checks wether user _addr has qi staked
    /// @param _addr the user address to check
    /// @return true if the user has qi in stake, false otherwise
    function isUser(address _addr) public view override returns (bool) {
        return users[_addr].amount != 0;
    }

    /// @notice returns staked amount of qi for user
    /// @param _addr the user address to check
    /// @return staked amount of qi
    function getStakedQi(address _addr) external view override returns (uint256) {
        return users[_addr].amount;
    }

    /// @dev eventual total supply, without needing users to trigger mint
    function eventualTotalSupply() external view override returns (uint256) {
        uint256 unclaimed;
        uint256 length = userList.length;

        for (uint256 i; i < length;) {
            unclaimed = unclaimed + _claimable(userList[i]);
            unchecked { ++i; }
        }

        return super.totalSupply() + unclaimed;
    }

    /// @dev explicity override multiple inheritance
    function totalSupply() public view override(VeERC20Upgradeable, IVeERC20) returns (uint256) {
        return super.totalSupply();
    }

    /// @dev eventual total balance of a user, without needing to claim
    function eventualBalanceOf(address account) external view override returns (uint256) {
        return balanceOf(account) + _claimable(account);
    }

    /// @dev explicity override multiple inheritance
    function balanceOf(address account) public view override(VeERC20Upgradeable, IVeERC20) returns (uint256) {
        return super.balanceOf(account);
    }

    /// @notice deposits QI into contract
    /// @param _amount the amount of qi to deposit
    function deposit(uint256 _amount) external override nonReentrant whenNotPaused {
        require(_amount > 0, "amount to deposit cannot be zero");

        // Request Qi from user
        qi.safeTransferFrom(msg.sender, address(this), _amount);

        if (isUser(msg.sender)) {
            // if user exists, first, claim his veQI
            _claim(msg.sender);
            // then, increment his holdings
            users[msg.sender].amount += _amount;
        } else {
            // add new user to mapping
            users[msg.sender].lastRelease = block.timestamp;
            users[msg.sender].amount = _amount;
            userListIndex[msg.sender] = userList.length;
            userList.push(msg.sender);
        }

        emit Staked(msg.sender, _amount);
    }

    /// @notice claims accumulated veQI
    function claim() external override nonReentrant whenNotPaused {
        require(isUser(msg.sender), "user has no stake");
        _claim(msg.sender);
    }

    /// @dev private claim function
    /// @param _addr the address of the user to claim from
    function _claim(address _addr) private {
        uint256 amount = _claimable(_addr);

        // update last release time
        users[_addr].lastRelease = block.timestamp;

        if (amount != 0) {
            emit Claimed(_addr, amount);
            _mint(_addr, amount);
        }
    }

    /// @notice Calculate the amount of veQI that can be claimed by user
    /// @param _addr the address to check
    /// @return amount of veQI that can be claimed by user
    function claimable(address _addr) external view returns (uint256) {
        require(_addr != address(0), "zero address");
        return _claimable(_addr);
    }

    /// @dev private claim function
    /// @param _addr the address of the user to claim from
    function _claimable(address _addr) private view returns (uint256) {
        UserInfo memory user = users[_addr];

        // get seconds elapsed since last claim
        uint256 secondsElapsed = block.timestamp - user.lastRelease;

        // calculate pending amount
        // Math.mwmul used to multiply wad numbers
        uint256 pending = Math.wmul(user.amount, secondsElapsed * generationRate);

        // get user's veQI balance
        uint256 userVeQiBalance = balanceOf(_addr);

        // user veQI balance cannot go above user.amount * maxCap
        uint256 maxVeQiCap = user.amount * maxCap;

        // first, check that user hasn"t reached the max limit yet
        if (userVeQiBalance < maxVeQiCap) {
            // then, check if pending amount will make user balance overpass maximum amount
            if ((userVeQiBalance + pending) > maxVeQiCap) {
                return maxVeQiCap - userVeQiBalance;
            } else {
                return pending;
            }
        }
        return 0;
    }

    /// @notice withdraws staked qi
    /// @param _amount the amount of qi to unstake
    /// Note Beware! you will loose all of your veQI if you unstake any amount of qi!
    function withdraw(uint256 _amount) external override nonReentrant whenNotPaused {
        require(_amount > 0, "amount to withdraw cannot be zero");
        require(users[msg.sender].amount >= _amount, "not enough balance");

        // reset last Release timestamp
        users[msg.sender].lastRelease = block.timestamp;

        // update his balance before burning or sending back qi
        unchecked {
            users[msg.sender].amount -= _amount;
        }

        // get user veQI balance that must be burned
        uint256 userVeQiBalance = balanceOf(msg.sender);

        _burn(msg.sender, userVeQiBalance);

        if (users[msg.sender].amount == 0) {
            _removeUserFromUserList(msg.sender);
        }

        // send back the staked qi
        qi.safeTransfer(msg.sender, _amount);

        emit Unstaked(msg.sender, _amount);
    }

    /// @notice removes a user from the user list
    /// @param _addr address to remove from list
    function _removeUserFromUserList(address _addr) private {
        uint256 index = userListIndex[_addr];

        require(userList[index] == _addr, "incorrect removal of user from list");

        address last = userList[userList.length - 1];
        userList[index] = last;
        userListIndex[last] = index;

        userList.pop();
        delete userListIndex[_addr];
    }
}

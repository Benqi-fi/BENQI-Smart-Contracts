pragma solidity 0.5.17;

contract ComptrollerInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata qiTokens) external returns (uint[] memory);
    function exitMarket(address qiToken) external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address qiToken, address minter, uint mintAmount) external returns (uint);
    function mintVerify(address qiToken, address minter, uint mintAmount, uint mintTokens) external;

    function redeemAllowed(address qiToken, address redeemer, uint redeemTokens) external returns (uint);
    function redeemVerify(address qiToken, address redeemer, uint redeemAmount, uint redeemTokens) external;

    function borrowAllowed(address qiToken, address borrower, uint borrowAmount) external returns (uint);
    function borrowVerify(address qiToken, address borrower, uint borrowAmount) external;

    function repayBorrowAllowed(
        address qiToken,
        address payer,
        address borrower,
        uint repayAmount) external returns (uint);
    function repayBorrowVerify(
        address qiToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex) external;

    function liquidateBorrowAllowed(
        address qiTokenBorrowed,
        address qiTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external returns (uint);
    function liquidateBorrowVerify(
        address qiTokenBorrowed,
        address qiTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens) external;

    function seizeAllowed(
        address qiTokenCollateral,
        address qiTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external returns (uint);
    function seizeVerify(
        address qiTokenCollateral,
        address qiTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external;

    function transferAllowed(address qiToken, address src, address dst, uint transferTokens) external returns (uint);
    function transferVerify(address qiToken, address src, address dst, uint transferTokens) external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address qiTokenBorrowed,
        address qiTokenCollateral,
        uint repayAmount) external view returns (uint, uint);
}

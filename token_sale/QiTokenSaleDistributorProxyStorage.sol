pragma solidity 0.6.12;


contract QiTokenSaleDistributorProxyStorage {
    // Current contract admin address
    address public admin;

    // Requested new admin for the contract
    address public pendingAdmin;

    // Current contract implementation address
    address public implementation;

    // Requested new contract implementation address
    address public pendingImplementation;
}

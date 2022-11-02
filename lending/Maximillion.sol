pragma solidity 0.5.17;

import "./QiAvax.sol";

/**
 * @title Benqi's Maximillion Contract
 * @author Benqi
 */
contract Maximillion {
    /**
     * @notice The default qiAvax market to repay in
     */
    QiAvax public qiAvax;

    /**
     * @notice Construct a Maximillion to repay max in a QiAvax market
     */
    constructor(QiAvax qiAvax_) public {
        qiAvax = qiAvax_;
    }

    /**
     * @notice msg.sender sends Avax to repay an account's borrow in the qiAvax market
     * @dev The provided Avax is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     */
    function repayBehalf(address borrower) public payable {
        repayBehalfExplicit(borrower, qiAvax);
    }

    /**
     * @notice msg.sender sends Avax to repay an account's borrow in a qiAvax market
     * @dev The provided Avax is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param qiAvax_ The address of the qiAvax contract to repay in
     */
    function repayBehalfExplicit(address borrower, QiAvax qiAvax_) public payable {
        uint received = msg.value;
        uint borrows = qiAvax_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            qiAvax_.repayBorrowBehalf.value(borrows)(borrower);
            msg.sender.transfer(received - borrows);
        } else {
            qiAvax_.repayBorrowBehalf.value(received)(borrower);
        }
    }
}

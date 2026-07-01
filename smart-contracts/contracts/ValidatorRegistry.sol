// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract ValidatorRegistry {
    address public owner;
    mapping(address => bool) private _validators;

    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function addValidator(address validator) external onlyOwner {
        require(validator != address(0), "ZERO_ADDRESS");
        require(!_validators[validator], "ALREADY_VALIDATOR");
        _validators[validator] = true;
        emit ValidatorAdded(validator);
    }

    function removeValidator(address validator) external onlyOwner {
        require(_validators[validator], "NOT_VALIDATOR");
        _validators[validator] = false;
        emit ValidatorRemoved(validator);
    }

    function isValidator(address validator) external view returns (bool) {
        return _validators[validator];
    }
}

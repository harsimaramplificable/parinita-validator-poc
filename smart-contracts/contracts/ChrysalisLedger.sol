// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ValidatorRegistry} from "./ValidatorRegistry.sol";

contract ChrysalisLedger {
    ValidatorRegistry public immutable registry;

    struct RecordAnchor {
        bytes32 checkpointId;
        string popId;
        uint8 region;
        uint8 recordType;
        uint64 timestamp;
        // keccak256 of the payload that was ML-DSA signed off-chain (FIPS 204 / Dilithium)
        bytes32 hashData;
        bool exists;
    }

    mapping(bytes32 => RecordAnchor) private _ledger; // recordId => anchor

    event RecordIndexed(
        bytes32 indexed recordId,
        string popId,
        uint8 indexed region,
        bytes32 checkpointBlock,
        bytes32 hashData
    );

    modifier onlyValidator() {
        require(registry.isValidator(msg.sender), "NOT_VALIDATOR");
        _;
    }

    constructor(address registry_) {
        registry = ValidatorRegistry(registry_);
    }

    function indexBatch(
        bytes32[] calldata recordIds,
        bytes32 checkpointId,
        string calldata popId,
        uint8 region,
        uint8 recordType,
        uint64 timestamp,
        bytes32 hashData
    ) external onlyValidator {
        for (uint256 i = 0; i < recordIds.length; i++) {
            bytes32 rid = recordIds[i];
            if (_ledger[rid].exists) continue; // idempotent
            _ledger[rid] = RecordAnchor(checkpointId, popId, region, recordType, timestamp, hashData, true);
            emit RecordIndexed(rid, popId, region, checkpointId, hashData);
        }
    }

    function getAnchor(bytes32 recordId) external view returns (RecordAnchor memory) {
        return _ledger[recordId];
    }
}

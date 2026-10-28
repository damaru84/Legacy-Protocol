// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LegacyVault} from "./LegacyVault.sol";

/**
 * @title LegacyFactory
 * @notice Despliega una LegacyVault por titular y mantiene un registro para la dApp.
 *         El titular de la bóveda es siempre quien llama a createVault.
 */
contract LegacyFactory {
    mapping(address => address[]) private _vaultsOf;

    event VaultCreated(address indexed owner, address indexed vault);

    function createVault(
        uint64 inactivityPeriod,
        uint64 challengePeriod,
        address[] calldata guardians,
        uint8 threshold
    ) external returns (address vault) {
        vault = address(
            new LegacyVault(msg.sender, inactivityPeriod, challengePeriod, guardians, threshold)
        );
        _vaultsOf[msg.sender].push(vault);
        emit VaultCreated(msg.sender, vault);
    }

    function vaultsOf(address owner) external view returns (address[] memory) {
        return _vaultsOf[owner];
    }
}

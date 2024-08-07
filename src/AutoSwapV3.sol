// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

// interfaces
import {ILSP1UniversalReceiverDelegate} from "@lukso/lsp1-contracts/contracts/ILSP1UniversalReceiverDelegate.sol";
import {ILSP7DigitalAsset} from "@lukso/lsp7-contracts/contracts/ILSP7DigitalAsset.sol";

// modules
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// libraries
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

// constants
import {_INTERFACEID_LSP1_DELEGATE} from "@lukso/lsp1-contracts/contracts/LSP1Constants.sol";
import {IERC725X} from "@erc725/smart-contracts/contracts/interfaces/IERC725X.sol";
import {_TYPEID_LSP7_TOKENSSENDER, _TYPEID_LSP7_TOKENSRECIPIENT, _INTERFACEID_LSP7} from "@lukso/lsp7-contracts/contracts/LSP7Constants.sol";

/// @title AutoSwapV3
/// @dev A contract for automatic token swaps using UniversalSwaps V3 contracts
/// @notice This contract implements automatic token swaps when receiving LSP7 tokens
contract AutoSwapV3 is ERC165, Ownable, ILSP1UniversalReceiverDelegate {
    using ERC165Checker for address;

    /// @notice Minimum amount of tokens required for a swap for each token address
    /// @dev Should be used to protect against sandwich attacks
    mapping(address => uint256) public minSwapAmount;

    /// @notice Determines the response behavior for failed swaps for each token address
    mapping(address => bool) public failedSwapResponse;

    /// @notice The address of the UniversalSwaps V3 Universal Router
    address public immutable universalRouter;

    /// @param initialOwner The address that will be set as the initial owner of the contract
    /// @param _universalRouter The address of the Uniswap V3 Universal Router
    constructor(
        address initialOwner,
        address _universalRouter
    ) Ownable(initialOwner) {
        universalRouter = _universalRouter;
    }

    /// @notice Sets the minimum swap amount for a specific token
    /// @param inputToken The address of the token to set the minimum swap amount for
    /// @param _minSwapAmount The minimum amount of tokens required for a swap
    function setMinSwapAmount(
        address inputToken,
        uint256 _minSwapAmount
    ) public onlyOwner {
        minSwapAmount[inputToken] = _minSwapAmount;
    }

    /// @notice Handles the universal receiver delegate function for LSP7 token transfers
    /// @param notifier The address of the LSP7 token contract
    /// @param value The amount of native tokens received (unused in this implementation)
    /// @param typeId The type ID of the received data
    /// @param data The received data
    /// @return result The result of the operation
    function universalReceiverDelegate(
        address notifier,
        uint256 value,
        bytes32 typeId,
        bytes memory data
    ) public virtual override returns (bytes memory result) {
        if (typeId == _TYPEID_LSP7_TOKENSRECIPIENT) {
            // The data sent according to the LSP7 specification
            (, , , uint256 amount, ) = abi.decode(
                data,
                (address, address, address, uint256, bytes)
            );
            return _autoSwapV3(notifier, amount);
        }

        return "LSP1: typeId out of scope";
    }

    /// @notice Internal function to perform the automatic swap
    /// @dev The swap's logic is built around the specification of the UniversalRouter
    /// The modified version of the UniversalRouter with UniversalSwapsV3 protocol
    /// @param notifier The address of the LSP7 token contract
    /// @param amount The amount of tokens to swap
    /// @return result The result of the swap operation
    function _autoSwapV3(
        address notifier,
        uint256 amount
    ) internal returns (bytes memory result) {
        if (minSwapAmount[notifier] == 0) {
            return "AutoSwapV3: minSwapAmount not set";
        }

        // The parameters for `V3_SWAP_EXACT_IN`
        bytes memory v3SwapExactInData = abi.encode(
            address(2), // The recipient of the output of the trade (Check constants)
            amount, // The amount of input tokens for the trade
            minSwapAmount[notifier], // The minimum amount of output tokens the user wants
            abi.encodePacked( // Hardcode the path to be the <token> <WLYX1>
                    notifier, // token
                    hex"002710", // Config bytes
                    hex"2dB41674F2b882889e5E1Bd09a3f3613952bC472" // WLYX1
                ),
            true // A flag for whether the input tokens should come from the msg.sender
        );

        // The parameters for `UNWRAP_WETH`
        bytes memory unwrapData = abi.encode(
            address(1), // The recipient of the LYX
            minSwapAmount[notifier] // The minimum required LYX to receive from the unwrapping
        );

        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = v3SwapExactInData;
        calldatas[1] = unwrapData;

        // Encode the execute(bytes,bytes[],uint256) call
        bytes memory swappingData = abi.encodeWithSelector(
            0x3593564c, // execute function selector
            hex"000c", // operations to execute: `V3_SWAP_EXACT_IN` + `UNWRAP_WETH`
            calldatas, // execution data
            block.timestamp // deadline
        );

        // Encode the authorization request to the Universal Router
        // with the swapping data
        bytes memory authorizationData = abi.encodeWithSelector(
            ILSP7DigitalAsset.authorizeOperator.selector,
            universalRouter,
            amount,
            swappingData
        );

        // Execute the authorization through the profile that received the tokens
        // and invoked the universalreceiver response
        (bool success, bytes memory result) = msg.sender.call{value: 0}(
            abi.encodeWithSelector(
                IERC725X.execute.selector,
                0, // OperationCall
                notifier, // The address of the token contract
                0, // value to send
                authorizationData // The authorizeOperator function data
            )
        );

        if (!success) {
            // Look for revert reason and bubble it up if present
            if (result.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly
                /// @solidity memory-safe-assembly
                assembly {
                    let returndata_size := mload(result)
                    revert(add(32, result), returndata_size)
                }
            } else {
                return ("Swap reverted");
            }
        }
    }

    // --- Overrides

    /// @notice Checks if the contract supports a given interface
    /// @param interfaceId The interface identifier to check
    /// @return bool True if the contract supports the interface, false otherwise
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == _INTERFACEID_LSP1_DELEGATE ||
            super.supportsInterface(interfaceId);
    }
}

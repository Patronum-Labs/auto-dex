// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.15;

// interfaces
import {ILSP1UniversalReceiverDelegate} from "@lukso/lsp1-contracts/contracts/ILSP1UniversalReceiverDelegate.sol";
import {ILSP7DigitalAsset} from "@lukso/lsp7-contracts/contracts/ILSP7DigitalAsset.sol";

// modules
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

// libraries
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

// constants
import {_INTERFACEID_LSP1_DELEGATE} from "@lukso/lsp1-contracts/contracts/LSP1Constants.sol";
import {_TYPEID_LSP7_TOKENSSENDER, _TYPEID_LSP7_TOKENSRECIPIENT, _INTERFACEID_LSP7} from "@lukso/lsp7-contracts/contracts/LSP7Constants.sol";

contract AutoSwapV3 is ERC165, Ownable, ILSP1UniversalReceiverDelegate {
    using ERC165Checker for address;

    mapping(address => uint256) public minSwapAmount;
    mapping(address => bool) public failedSwapResponse;
    address public immutable universalRouter;

    constructor(
        address initialOwner,
        address _universalRouter
    ) Ownable(initialOwner) {
        universalRouter = _universalRouter;
    }

    function setMinSwapAmount(
        address inputToken,
        uint256 _minSwapAmount
    ) public onlyOwner {
        minSwapAmount[inputToken] = _minSwapAmount;
    }

    function setFailedSwapResponse(
        address inputToken,
        bool failedSwapResponse_
    ) public onlyOwner {
        failedSwapResponse[inputToken] = failedSwapResponse_;
    }

    function universalReceiverDelegate(
        address notifier,
        uint256 /*value*/,
        bytes32 typeId,
        bytes memory data
    ) public virtual override returns (bytes memory) {
        if (typeId == _TYPEID_LSP7_TOKENSRECIPIENT) {
            (, , , amount, ) = abi.decode(
                data,
                (address, address, address, uint256, bytes)
            );
            return _autoSwapV3(notifier, amount);
        }

        return "LSP1: typeId out of scope";
    }

    function _autoSwapV3(
        address notifier,
        uint256 amount
    ) internal returns (bytes memory) {
        if (minSwapAmount[notifier] == 0) {
            return "AutoSwapV3: minSwapAmount not set";
        }

        bytes memory v3SwapExactInData = abi.encode(
            address(1),
            amount,
            minSwapAmount[notifier],
            abi.encodePacked( // Hardcode the path to be the <token> <WLYX1>
                    notifier, // token
                    hex"002710", // Config bytes
                    hex"2dB41674F2b882889e5E1Bd09a3f3613952bC472" // WLYX1
                ),
            true
        );

        bytes memory unwrapData = abi.encode(
            address(1),
            minSwapAmount[notifier]
        );

        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = v3SwapExactInData;
        calldatas[1] = unwrapData;

        bytes swappingData = abi.encodeWithSelector(
            0x3593564c,
            hex"000c",
            calldatas,
            block.timestamp
        );

        bytes authorizationData = abi.encodeWithSelector(
            ILSP7DigitalAsset.authorizeOperator.selector,
            universalRouter,
            amount,
            swappingData
        );

        try
            IERC725X(msg.sender).execute(0, notifier, 0, authorizationData)
        {} catch {
            if (failedSwapResponse[notifier]) {
                revert("AutoSwapV3: failed to execute the swap");
            }
            return "AutoSwapV3: failed to execute the swap";
        }
    }

    // --- Overrides

    /**
     * @inheritdoc ERC165
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == _INTERFACEID_LSP1_DELEGATE ||
            super.supportsInterface(interfaceId);
    }
}

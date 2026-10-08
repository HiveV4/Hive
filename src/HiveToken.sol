// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title HiveToken ($HIVE)
/// @notice Fixed-supply ERC-20. The whole launch supply is minted once, in the constructor, to the colony treasury,
///         which seeds it into the canonical Uniswap v4 pool. There is no owner, no mint function, no transfer tax,
///         no blocklist and no pause. Anyone may burn their own tokens; burns reduce `totalSupply` but never change
///         `LAUNCH_SUPPLY`, the fixed denominator used by every supply-based trading limit.
contract HiveToken is ERC20 {
    /// @notice Immutable launch supply, 1,000,000,000 HIVE. Denominator for every percentage-of-supply trade limit.
    uint256 public constant LAUNCH_SUPPLY = 1_000_000_000e18;

    string private _description;
    string private _website;
    string private _image;

    error ZeroRecipient();

    constructor(
        string memory name_,
        string memory symbol_,
        address supplyRecipient,
        string memory description_,
        string memory website_,
        string memory image_
    ) ERC20(name_, symbol_, 18) {
        if (supplyRecipient == address(0)) revert ZeroRecipient();
        _description = description_;
        _website = website_;
        _image = image_;
        _mint(supplyRecipient, LAUNCH_SUPPLY);
    }

    /// @notice Burns `amount` of the caller's tokens.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Presentation metadata read by Programmable and terminals: (description, website, image, extraData).
    function metadata()
        external
        view
        returns (string memory description, string memory website, string memory image, bytes memory extraData)
    {
        return (_description, _website, _image, "");
    }
}

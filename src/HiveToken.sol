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
    string private _x;

    error ZeroRecipient();
    /// @dev metadata strings are joined into JSON as they are, so they may not contain `"`, `\` or control characters
    error UnsafeMetadata();

    constructor(
        string memory name_,
        string memory symbol_,
        address supplyRecipient,
        string memory description_,
        string memory website_,
        string memory image_,
        string memory x_
    ) ERC20(name_, symbol_, 18) {
        if (supplyRecipient == address(0)) revert ZeroRecipient();
        _requireJsonSafe(name_);
        _requireJsonSafe(symbol_);
        _requireJsonSafe(description_);
        _requireJsonSafe(website_);
        _requireJsonSafe(image_);
        _requireJsonSafe(x_);
        _description = description_;
        _website = website_;
        _image = image_;
        _x = x_;
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

    /// @notice The same presentation metadata plus the X profile, as inline JSON
    ///         (`data:application/json;base64,…`): name, symbol, description, image, website / external_url, x / twitter.
    ///         Empty fields are left out.
    function tokenURI() external view returns (string memory) {
        bytes memory json = abi.encodePacked(
            '{"name":"',
            name,
            '","symbol":"',
            symbol,
            '"',
            _field("description", _description),
            _field("image", _image),
            _field("website", _website),
            _field("external_url", _website),
            _field("x", _x),
            _field("twitter", _x),
            "}"
        );
        return string(abi.encodePacked("data:application/json;base64,", _base64(json)));
    }

    function _field(string memory key, string memory value) private pure returns (bytes memory) {
        return bytes(value).length == 0 ? bytes("") : abi.encodePacked(',"', key, '":"', value, '"');
    }

    function _requireJsonSafe(string memory s) private pure {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == '"' || b[i] == "\\" || uint8(b[i]) < 0x20) revert UnsafeMetadata();
        }
    }

    function _base64(bytes memory data) private pure returns (string memory) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 len = data.length;
        bytes memory out = new bytes(4 * ((len + 2) / 3));
        uint256 j;
        for (uint256 i; i < len; i += 3) {
            uint256 n = uint256(uint8(data[i])) << 16;
            if (i + 1 < len) n |= uint256(uint8(data[i + 1])) << 8;
            if (i + 2 < len) n |= uint256(uint8(data[i + 2]));
            out[j++] = table[(n >> 18) & 63];
            out[j++] = table[(n >> 12) & 63];
            out[j++] = i + 1 < len ? table[(n >> 6) & 63] : bytes1("=");
            out[j++] = i + 2 < len ? table[n & 63] : bytes1("=");
        }
        return string(out);
    }
}

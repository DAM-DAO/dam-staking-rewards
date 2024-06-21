// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./interfaces/core/IFactory.sol";
import "./interfaces/core/IWalletApeCoin.sol";

struct LockedBalance {
    uint256 amount;
    uint256 end;
}

struct DetailedBalance {
    uint256 availableBalance;
    LockedBalance[] locks;
}

error NotEnoughApeCoin();
error InvalidLockYear();
error NotImplemented();
error ReceiverNotCyanWallet();
error SenderNotMainWallet();
error NotEnoughAsset();
error SenderNotOwner();

contract DamVault is ERC4626, Ownable, Pausable {
    using SafeCast for uint256;

    event UpdatedBlastBridgeMinGasLimit(uint32 _minGasLimit);
    event UpdatedLockEndTime(uint8 lockYear, uint256 endTime);

    uint256 private constant YEAR = 365 * 86400;

    IFactory private constant walletFactory = IFactory(0xed567F1D7BC0fc08cc0967139C0545e73cA4587D);
    IMessenger private constant messenger = IMessenger(0x5D4472f31Bd9385709ec61305AFc749F0fA8e9d0);
    address public constant dam = 0x52B438b2FeE2AdeEf6d4146095ACE07772C1ED0A;
    uint32 public minGasLimitOnBlastBridge = 200000;
    uint256 private _totalSupply;
    uint256 private _numberOfStakeholders;

    mapping(address => mapping(uint8 => uint256)) private _lockAmount;

    mapping(uint8 => uint256) public lockEndTime;

    constructor(ERC20 _asset, address _owner) ERC4626(_asset) ERC20("dAPE", "dAPE") Ownable() {
        _transferOwnership(_owner);
    }

    function depositWithLock(
        uint256 assets,
        address receiver,
        uint8 lockYear
    ) external whenNotPaused returns (uint256) {
        address senderCyanWallet = walletFactory.getOrDeployWallet(msg.sender);
        if (senderCyanWallet != receiver) revert ReceiverNotCyanWallet();
        if (lockYear > 5) {
            revert InvalidLockYear();
        }
        if (lockYear > 0 && block.timestamp > lockEndTime[lockYear]) {
            revert InvalidLockYear();
        }
        if (assets > maxDeposit(receiver)) revert NotEnoughAsset();

        uint256 shares = previewDeposit(assets);
        unchecked {
            _lockAmount[receiver][lockYear] += shares;
        }
        _deposit(msg.sender, receiver, assets, shares);
        _sendMessageDeposit(msg.sender, assets, lockYear);
        return shares;
    }

    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256) {
        revert NotImplemented();
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        revert NotImplemented();
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        address senderCyanWallet = walletFactory.getOrDeployWallet(msg.sender);
        if (senderCyanWallet == msg.sender) revert SenderNotMainWallet();
        if (senderCyanWallet != receiver) revert ReceiverNotCyanWallet();
        if (msg.sender != owner) revert SenderNotOwner();

        uint256 shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        _sendMessageWithdraw(msg.sender, assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        revert NotImplemented();
    }

    function totalBalance(address account) public view returns (uint256) {
        return _totalBalance(account);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return _availableBalance(owner);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return _availableBalance(owner);
    }

    function availableBalanceOf(address addr) external view returns (uint256) {
        return _availableBalance(addr);
    }

    function totalAssets() public view override returns (uint256) {
        return _totalSupply;
    }

    function getDetailedLockInfo(address addr) external view returns (DetailedBalance memory) {
        LockedBalance[] memory locks = new LockedBalance[](6);
        uint256 balance = _lockAmount[addr][0];
        for (uint8 i = 1; i <= 5; ++i) {
            LockedBalance memory lock = LockedBalance({ amount: _lockAmount[addr][i], end: lockEndTime[i] });
            if (lock.end < block.timestamp) {
                unchecked {
                    balance = balance + lock.amount;
                }
                locks[i] = LockedBalance({ amount: 0, end: 0 });
            } else {
                locks[i] = lock;
            }
        }
        locks[0].amount = balance;
        return DetailedBalance({ locks: locks, availableBalance: balance });
    }

    function numberOfStakeholders() public view returns (uint256) {
        return _numberOfStakeholders;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _updateLockInfo(receiver);
        unchecked {
            _totalSupply = _totalSupply + assets;
        }
        SafeERC20.safeTransferFrom(ERC20(asset()), caller, receiver, assets);
        IWalletApeCoin wallet = IWalletApeCoin(receiver);
        if (_totalBalance(receiver) == shares) {
            wallet.executeModule(
                abi.encodeWithSelector(IWalletApeCoin.depositApeCoinAndCreateDamLock.selector, assets)
            );
            unchecked {
                _numberOfStakeholders += 1;
            }
        } else {
            wallet.executeModule(abi.encodeWithSelector(IWalletApeCoin.increaseApeCoinStakeOnDamLock.selector, assets));
        }
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        _updateLockInfo(receiver);
        if (_totalSupply < assets) revert NotEnoughAsset();
        if (_lockAmount[receiver][0] < shares) revert NotEnoughAsset();
        unchecked {
            _totalSupply = _totalSupply - assets;
        }
        unchecked {
            _lockAmount[receiver][0] = _lockAmount[receiver][0] - shares;
        }
        IWalletApeCoin wallet = IWalletApeCoin(receiver);
        wallet.executeModule(abi.encodeWithSelector(IWalletApeCoin.withdrawApeCoinAndRemoveDamLock.selector, assets));
        if (totalBalance(receiver) > 0) {
            wallet.executeModule(abi.encodeWithSelector(IWalletApeCoin.createDamLock.selector));
        } else {
            unchecked {
                _numberOfStakeholders -= 1;
            }
        }
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256 shares) {
        return assets;
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256 assets) {
        return shares;
    }

    function _availableBalance(address addr) private view returns (uint256) {
        uint256 balance = _lockAmount[addr][0];
        for (uint8 i = 1; i <= 5; ++i) {
            uint256 lockedBalance = _lockAmount[addr][i];
            if (lockEndTime[i] < block.timestamp) {
                unchecked {
                    balance = balance + lockedBalance;
                }
            }
        }
        return balance;
    }

    function _totalBalance(address account) private view returns (uint256) {
        unchecked {
            return
                _lockAmount[account][0] +
                _lockAmount[account][1] +
                _lockAmount[account][2] +
                _lockAmount[account][3] +
                _lockAmount[account][4] +
                _lockAmount[account][5];
        }
    }

    function _updateLockInfo(address addr) private {
        for (uint8 i = 1; i <= 5; ++i) {
            if (lockEndTime[i] < block.timestamp) {
                unchecked {
                    _lockAmount[addr][0] = _lockAmount[addr][0] + _lockAmount[addr][i];
                }
                _lockAmount[addr][i] = 0;
            }
        }
    }

    function _sendMessageDeposit(address addr, uint256 amount, uint8 lockYear) private {
        messenger.sendMessage(dam, abi.encodeCall(IDam.deposit, (addr, amount, lockYear)), minGasLimitOnBlastBridge);
    }

    function _sendMessageWithdraw(address addr, uint256 amount) private {
        messenger.sendMessage(dam, abi.encodeCall(IDam.withdraw, (addr, amount)), minGasLimitOnBlastBridge);
    }

    function setBlastBridgeMinGasLimit(uint32 _minGasLimit) external onlyOwner {
        minGasLimitOnBlastBridge = _minGasLimit;
        emit UpdatedBlastBridgeMinGasLimit(_minGasLimit);
    }

    function setLockEndTime(uint8 lockYear, uint256 endTime) external onlyOwner {
        uint256 currentEndTime = lockEndTime[lockYear];
        if (currentEndTime != 0 && endTime >= currentEndTime) {
            revert InvalidLockYear();
        }
        lockEndTime[lockYear] = endTime;
        emit UpdatedLockEndTime(lockYear, endTime);
    }

    function setPause() external onlyOwner {
        if (paused()) {
            _unpause();
        } else {
            _pause();
        }
    }
}

interface IMessenger {
    function sendMessage(address _target, bytes calldata _message, uint32 _minGasLimit) external payable;
}

interface IDam {
    function deposit(address, uint256, uint8) external;

    function withdraw(address, uint256) external;
}

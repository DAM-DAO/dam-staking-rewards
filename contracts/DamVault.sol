// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./interfaces/IApeCoinStaking.sol";
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

contract DamVault is ERC4626, Ownable, Pausable {
    using SafeCast for uint256;

    event UpdatedBlastBridgeMinGasLimit(uint32 _minGasLimit);
    event UpdatedLockEndTime(uint8 lockYear, uint256 endTime);

    uint256 private constant YEAR = 365 * 86400;
    IApeCoinStaking private constant apeCoinStaking = IApeCoinStaking(0x5954aB967Bc958940b7EB73ee84797Dc8a2AFbb9);

    IFactory private walletFactory = IFactory(0x0165878A594ca255338adfa4d48449f69242Eb8F);
    IMessenger private messenger = IMessenger(0x5D4472f31Bd9385709ec61305AFc749F0fA8e9d0);
    address public dam = address(0x5D4472f31Bd9385709ec61305AFc749F0fA8e9d0); // TODO have to setup after deployment
    uint32 public minGasLimitOnBlastBridge = 200000;
    uint256 private _totalSupply;
    uint256 private _numberOfStakeholders;

    mapping(address => mapping(uint8 => uint256)) private _lockAmount;

    mapping(uint8 => uint256) public lockEndTime;

    constructor(
        ERC20 _asset,
        address _factory,
        address _messenger,
        address _dam
    ) ERC4626(_asset) ERC20("vAPE", "vAPE") Ownable() {
        walletFactory = IFactory(_factory);
        messenger = IMessenger(_messenger);
        dam = _dam;
    }

    function depositWithLock(uint256 assets, address receiver, uint8 lockYear) external whenNotPaused returns (uint256) {
        address senderCyanWallet = walletFactory.getOrDeployWallet(msg.sender);
        require(senderCyanWallet == receiver, "Receiver should be cyan wallet");
        require(lockYear <= 5, "DamVault: invalid lock year");
        require(lockYear > 0, "DamVault: invalid lock year");
        require(block.timestamp < lockEndTime[lockYear], "DamVault: lock year has ended");
        require(assets <= maxDeposit(receiver), "ERC4626: deposit more than max");

        uint256 shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
        _sendMessageDeposit(msg.sender, assets, lockYear);
        return shares;
    }

    function deposit(uint256 assets, address receiver) public whenNotPaused override returns (uint256) {
        address senderCyanWallet = walletFactory.getOrDeployWallet(msg.sender);
        require(senderCyanWallet == receiver, "Receiver should be cyan wallet");
        require(assets <= maxDeposit(receiver), "ERC4626: deposit more than max");

        uint256 shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
        _lockAmount[receiver][0] = _lockAmount[receiver][0] + shares;
        _sendMessageDeposit(msg.sender, assets, 0);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        revert("Deprecated");
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        address senderCyanWallet = walletFactory.getOrDeployWallet(msg.sender);
        require(senderCyanWallet != msg.sender, "Sender should be main wallet");
        require(senderCyanWallet == receiver, "Receiver should be cyan wallet");
        require(msg.sender == owner, "Sender should be owner");
        require(assets <= maxWithdraw(receiver), "ERC4626: withdraw more than max");

        uint256 shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        _sendMessageWithdraw(msg.sender, assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        revert("Deprecated");
    }

    function totalBalance(address account) public view returns (uint256) {
        return
            _lockAmount[account][0] +
            _lockAmount[account][1] +
            _lockAmount[account][2] +
            _lockAmount[account][3] +
            _lockAmount[account][4] +
            _lockAmount[account][5];
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
                balance = balance + lock.amount;
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
        _totalSupply = _totalSupply + assets;
        SafeERC20.safeTransferFrom(ERC20(asset()), caller, receiver, assets);
        IWalletApeCoin wallet = IWalletApeCoin(receiver);
        if (totalBalance(receiver) == 0) {
            wallet.executeModule(
                abi.encodeWithSelector(IWalletApeCoin.depositApeCoinAndCreateDamLock.selector, assets)
            );
            _numberOfStakeholders += 1;
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
        _totalSupply = _totalSupply - assets;
        _lockAmount[receiver][0] = _lockAmount[receiver][0] - shares;
        IWalletApeCoin wallet = IWalletApeCoin(receiver);
        wallet.executeModule(abi.encodeWithSelector(IWalletApeCoin.withdrawApeCoinAndRemoveDamLock.selector, assets));
        if (totalBalance(receiver) > 0) {
            wallet.executeModule(abi.encodeWithSelector(IWalletApeCoin.createDamLock.selector));
        } else {
            _numberOfStakeholders -= 1;
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
                balance = balance + lockedBalance;
            }
        }
        return balance;
    }

    function _updateLockInfo(address addr) private {
        for (uint8 i = 1; i <= 5; ++i) {
            if (lockEndTime[i] < block.timestamp) {
                _lockAmount[addr][0] = _lockAmount[addr][0] + _lockAmount[addr][i];
                _lockAmount[addr][i] = 0;
            }
        }
    }

    function _sendMessageDeposit(address addr, uint256 amount, uint8 lockYear) private {
        messenger.sendMessage(
            dam,
            abi.encodeCall(IDam.deposit, (addr, amount, lockYear)),
            minGasLimitOnBlastBridge
        );
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
        if (currentEndTime != 0) {
            require(currentEndTime > endTime, "DamVault: only decrease lock time is allowed");
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
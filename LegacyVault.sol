// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LegacyVault
 * @notice Bóveda sucesoria para ETH y tokens ERC-20 (MVP de Legacy Protocol v1.3).
 *
 * Una bóveda por titular. Los fondos se depositan en este contrato y solo pueden
 * moverse de dos maneras: (a) el titular los retira mientras el plan está ACTIVO,
 * o (b) los beneficiarios los reclaman una vez completado el proceso sucesorio.
 *
 * Máquina de estados:
 *   Active -> UnderReview -> InChallenge -> ClaimsEnabled -> Finalized
 *
 *  - Active:        el titular opera, confirma actividad (ping) y edita el plan.
 *  - UnderReview:   venció el plazo de inactividad; los guardianes votan.
 *  - InChallenge:   se alcanzó el umbral; el titular puede objetar con ping().
 *  - ClaimsEnabled: terminó la impugnación; cada beneficiario llama claim(asset).
 *  - Finalized:     todas las asignaciones fueron reclamadas.
 *
 * Limitaciones conocidas del MVP (ver whitepaper):
 *  - No redistribuye asignaciones no reclamadas.
 *  - No prueba fallecimiento: inactividad + guardianes son señales operativas.
 *  - La transición por plazo requiere que alguien envíe la transacción
 *    (startReview / enableClaims son públicas, cualquiera puede llamarlas).
 *  - El redondeo por división entera deja "polvo" (wei) sin asignar.
 */
contract LegacyVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────────── Tipos ─────────────────────────────

    enum State {
        Active,
        UnderReview,
        InChallenge,
        ClaimsEnabled,
        Finalized
    }

    struct Share {
        address beneficiary;
        uint16 bps; // puntos básicos: 10_000 = 100 %
    }

    // ─────────────────────────── Constantes ──────────────────────────

    /// @dev Dirección que representa ETH nativo en el plan.
    address public constant ETH = address(0);
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_BENEFICIARIES = 20;
    uint256 public constant MAX_ASSETS = 20;
    uint256 public constant MAX_GUARDIANS = 10;

    // ───────────────────────────── Estado ────────────────────────────

    address public immutable owner;

    State public state;
    uint64 public inactivityPeriod;
    uint64 public challengePeriod;
    uint64 public lastActivity;
    uint64 public challengeEnd;

    address[] private _guardians;
    mapping(address => bool) public isGuardian;
    uint8 public threshold;
    uint256 public reviewRound;
    uint8 public approvalCount;
    mapping(uint256 => mapping(address => bool)) public hasApproved;

    address[] private _assets;
    mapping(address => bool) public isAsset;
    mapping(address => Share[]) private _shares;

    /// @dev Saldo congelado de cada activo al habilitar las reclamaciones.
    mapping(address => uint256) public snapshot;
    mapping(address => mapping(address => bool)) public claimed;
    uint256 public pendingClaims;

    // ───────────────────────────── Eventos ───────────────────────────

    event StateChanged(State indexed newState);
    event Activity(address indexed owner, uint64 timestamp);
    event AllocationSet(address indexed asset, uint256 beneficiaries);
    event AllocationRemoved(address indexed asset);
    event GuardiansSet(address[] guardians, uint8 threshold);
    event PeriodsSet(uint64 inactivityPeriod, uint64 challengePeriod);
    event ReviewStarted(uint256 indexed round);
    event GuardianApproved(uint256 indexed round, address indexed guardian, uint8 approvals);
    event ChallengeStarted(uint64 challengeEnd);
    event ChallengeRaised(address indexed owner);
    event ClaimsEnabled(uint256 pendingClaims);
    event Claimed(address indexed asset, address indexed beneficiary, uint256 amount);
    event Deposited(address indexed asset, address indexed from, uint256 amount);
    event Withdrawn(address indexed asset, address indexed to, uint256 amount);

    // ───────────────────────────── Errores ───────────────────────────

    error NotOwner();
    error NotGuardian();
    error WrongState(State current);
    error ZeroAddress();
    error ZeroValue();
    error InvalidGuardians();
    error InvalidShare();
    error DuplicateBeneficiary();
    error BadTotal(uint256 total);
    error TooMany();
    error NotInactiveYet(uint64 availableAt);
    error EmptyPlan();
    error AlreadyApproved();
    error ChallengeNotOver(uint64 endsAt);
    error NotBeneficiary();
    error AlreadyClaimed();
    error TransferFailed();

    // ─────────────────────────── Modificadores ───────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier inState(State s) {
        if (state != s) revert WrongState(state);
        _;
    }

    // ──────────────────────────── Constructor ────────────────────────

    constructor(
        address owner_,
        uint64 inactivityPeriod_,
        uint64 challengePeriod_,
        address[] memory guardians_,
        uint8 threshold_
    ) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        _setPeriods(inactivityPeriod_, challengePeriod_);
        _setGuardians(guardians_, threshold_);
        lastActivity = uint64(block.timestamp);
        emit StateChanged(State.Active);
    }

    /// @dev Solo se aceptan depósitos de ETH antes de habilitar reclamaciones,
    ///      para que no queden fondos fuera del snapshot.
    receive() external payable {
        if (state >= State.ClaimsEnabled) revert WrongState(state);
        emit Deposited(ETH, msg.sender, msg.value);
    }

    // ─────────────────── Fondos (solo con plan ACTIVO) ───────────────

    /// @notice Deposita tokens ERC-20 (requiere approve previo). También se
    ///         pueden enviar con un transfer directo.
    function depositToken(address token, uint256 amount) external onlyOwner inState(State.Active) {
        if (token == ETH) revert ZeroAddress();
        if (amount == 0) revert ZeroValue();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _touch();
        emit Deposited(token, msg.sender, amount);
    }

    function withdrawETH(address payable to, uint256 amount)
        external
        onlyOwner
        inState(State.Active)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        _touch();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(ETH, to, amount);
    }

    function withdrawToken(address token, address to, uint256 amount)
        external
        onlyOwner
        inState(State.Active)
        nonReentrant
    {
        if (token == ETH || to == address(0)) revert ZeroAddress();
        _touch();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // ─────────────────── Configuración (solo ACTIVO) ─────────────────

    /**
     * @notice Define (o reemplaza) la distribución de un activo.
     * @param asset address(0) para ETH, o la dirección del token ERC-20.
     * @param newShares beneficiarios y porcentajes en bps; deben sumar 10_000.
     *                  Un arreglo vacío elimina el activo del plan.
     */
    function setAllocation(address asset, Share[] calldata newShares)
        external
        onlyOwner
        inState(State.Active)
    {
        _touch();

        if (newShares.length == 0) {
            _removeAsset(asset);
            return;
        }
        if (newShares.length > MAX_BENEFICIARIES) revert TooMany();

        uint256 total;
        for (uint256 i = 0; i < newShares.length; i++) {
            Share calldata s = newShares[i];
            if (s.beneficiary == address(0) || s.bps == 0) revert InvalidShare();
            for (uint256 j = 0; j < i; j++) {
                if (newShares[j].beneficiary == s.beneficiary) revert DuplicateBeneficiary();
            }
            total += s.bps;
        }
        if (total != BPS_DENOMINATOR) revert BadTotal(total);

        if (!isAsset[asset]) {
            if (_assets.length >= MAX_ASSETS) revert TooMany();
            isAsset[asset] = true;
            _assets.push(asset);
        }

        delete _shares[asset];
        for (uint256 i = 0; i < newShares.length; i++) {
            _shares[asset].push(newShares[i]);
        }
        emit AllocationSet(asset, newShares.length);
    }

    function setGuardians(address[] calldata guardians_, uint8 threshold_)
        external
        onlyOwner
        inState(State.Active)
    {
        _touch();
        _setGuardians(guardians_, threshold_);
    }

    function setPeriods(uint64 inactivityPeriod_, uint64 challengePeriod_)
        external
        onlyOwner
        inState(State.Active)
    {
        _touch();
        _setPeriods(inactivityPeriod_, challengePeriod_);
    }

    // ───────────────── Confirmación de actividad / impugnación ───────

    /**
     * @notice El titular confirma que sigue activo.
     *  - En Active reinicia el contador de inactividad.
     *  - En UnderReview o InChallenge aborta el proceso (impugnación del titular)
     *    y devuelve el plan a Active.
     *  No se puede usar una vez habilitadas las reclamaciones.
     */
    function ping() external onlyOwner {
        State s = state;
        if (s == State.ClaimsEnabled || s == State.Finalized) revert WrongState(s);

        _touch();
        if (s != State.Active) {
            approvalCount = 0;
            challengeEnd = 0;
            state = State.Active;
            emit ChallengeRaised(owner);
            emit StateChanged(State.Active);
        }
    }

    // ───────────────────── Activación controlada ─────────────────────

    /// @notice Cualquiera puede iniciar la revisión cuando venció el plazo de inactividad.
    function startReview() external inState(State.Active) {
        uint64 availableAt = lastActivity + inactivityPeriod;
        if (block.timestamp < availableAt) revert NotInactiveYet(availableAt);
        if (_assets.length == 0) revert EmptyPlan();

        reviewRound += 1;
        approvalCount = 0;
        state = State.UnderReview;
        emit ReviewStarted(reviewRound);
        emit StateChanged(State.UnderReview);
    }

    /// @notice Un guardián aprueba la activación. Al llegar al umbral comienza la impugnación.
    function approveActivation() external inState(State.UnderReview) {
        if (!isGuardian[msg.sender]) revert NotGuardian();
        if (hasApproved[reviewRound][msg.sender]) revert AlreadyApproved();

        hasApproved[reviewRound][msg.sender] = true;
        approvalCount += 1;
        emit GuardianApproved(reviewRound, msg.sender, approvalCount);

        if (approvalCount >= threshold) {
            challengeEnd = uint64(block.timestamp) + challengePeriod;
            state = State.InChallenge;
            emit ChallengeStarted(challengeEnd);
            emit StateChanged(State.InChallenge);
        }
    }

    /// @notice Cualquiera puede habilitar las reclamaciones al terminar la impugnación.
    ///         Congela el saldo de cada activo para calcular las cuotas.
    function enableClaims() external inState(State.InChallenge) {
        if (block.timestamp < challengeEnd) revert ChallengeNotOver(challengeEnd);

        uint256 pending;
        for (uint256 i = 0; i < _assets.length; i++) {
            address a = _assets[i];
            snapshot[a] = a == ETH ? address(this).balance : IERC20(a).balanceOf(address(this));
            pending += _shares[a].length;
        }
        pendingClaims = pending;
        state = State.ClaimsEnabled;
        emit ClaimsEnabled(pending);
        emit StateChanged(State.ClaimsEnabled);
    }

    // ───────────────────────── Reclamaciones ─────────────────────────

    /// @notice El beneficiario retira su cuota de un activo. No se puede reclamar dos veces.
    function claim(address asset) external nonReentrant inState(State.ClaimsEnabled) {
        if (claimed[asset][msg.sender]) revert AlreadyClaimed();
        (bool found, uint16 bps) = _bpsOf(asset, msg.sender);
        if (!found) revert NotBeneficiary();

        // Effects antes de interactions
        claimed[asset][msg.sender] = true;
        pendingClaims -= 1;
        uint256 amount = (snapshot[asset] * bps) / BPS_DENOMINATOR;

        if (pendingClaims == 0) {
            state = State.Finalized;
            emit StateChanged(State.Finalized);
        }

        if (amount > 0) {
            if (asset == ETH) {
                (bool ok, ) = payable(msg.sender).call{value: amount}("");
                if (!ok) revert TransferFailed();
            } else {
                IERC20(asset).safeTransfer(msg.sender, amount);
            }
        }
        emit Claimed(asset, msg.sender, amount);
    }

    // ─────────────────────────── Consultas ───────────────────────────

    function getAssets() external view returns (address[] memory) {
        return _assets;
    }

    function getShares(address asset) external view returns (Share[] memory) {
        return _shares[asset];
    }

    function getGuardians() external view returns (address[] memory) {
        return _guardians;
    }

    /// @notice Monto que `account` puede reclamar hoy de `asset` (0 si no corresponde).
    function claimableOf(address asset, address account) external view returns (uint256) {
        if (state != State.ClaimsEnabled || claimed[asset][account]) return 0;
        (bool found, uint16 bps) = _bpsOf(asset, account);
        return found ? (snapshot[asset] * bps) / BPS_DENOMINATOR : 0;
    }

    /// @notice Momento a partir del cual puede iniciarse la revisión.
    function reviewAvailableAt() external view returns (uint64) {
        return lastActivity + inactivityPeriod;
    }

    // ──────────────────────────── Internas ───────────────────────────

    function _touch() private {
        lastActivity = uint64(block.timestamp);
        emit Activity(owner, lastActivity);
    }

    function _bpsOf(address asset, address account) private view returns (bool, uint16) {
        Share[] storage list = _shares[asset];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].beneficiary == account) return (true, list[i].bps);
        }
        return (false, 0);
    }

    function _removeAsset(address asset) private {
        if (!isAsset[asset]) return;
        delete _shares[asset];
        isAsset[asset] = false;
        uint256 len = _assets.length;
        for (uint256 i = 0; i < len; i++) {
            if (_assets[i] == asset) {
                _assets[i] = _assets[len - 1];
                _assets.pop();
                break;
            }
        }
        emit AllocationRemoved(asset);
    }

    function _setPeriods(uint64 inactivity_, uint64 challenge_) private {
        if (inactivity_ == 0 || challenge_ == 0) revert ZeroValue();
        inactivityPeriod = inactivity_;
        challengePeriod = challenge_;
        emit PeriodsSet(inactivity_, challenge_);
    }

    function _setGuardians(address[] memory list, uint8 threshold_) private {
        if (list.length == 0 || list.length > MAX_GUARDIANS) revert InvalidGuardians();
        if (threshold_ == 0 || threshold_ > list.length) revert InvalidGuardians();

        for (uint256 i = 0; i < _guardians.length; i++) {
            isGuardian[_guardians[i]] = false;
        }
        delete _guardians;

        for (uint256 i = 0; i < list.length; i++) {
            address g = list[i];
            if (g == address(0) || g == owner || isGuardian[g]) revert InvalidGuardians();
            isGuardian[g] = true;
            _guardians.push(g);
        }
        threshold = threshold_;
        emit GuardiansSet(list, threshold_);
    }
}

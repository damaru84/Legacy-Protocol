# Legacy Protocol: smart contracts (MVP v1.3)

Contratos Solidity del whitepaper *Legacy Protocol*: planificación sucesoria de ETH y ERC-20.

## Contratos

| Archivo | Rol |
|---|---|
| `contracts/LegacyVault.sol` | Bóveda del titular: custodia, plan por activo, guardianes, máquina de estados, `claim()` |
| `contracts/LegacyFactory.sol` | Despliega una bóveda por titular y las registra |
| `contracts/mocks/MockERC20.sol` | Token de prueba (6 decimales) |

## Flujo

1. El titular crea la bóveda (`LegacyFactory.createVault`) con plazos, guardianes y umbral.
2. `setAllocation(asset, shares)` por activo (`address(0)` = ETH); cada activo suma 10.000 bps.
3. Deposita ETH (transferencia directa) y tokens (`depositToken` o transfer).
4. Si deja de dar señales: `startReview()` → `approveActivation()` (guardianes) → impugnación → `enableClaims()`.
5. El titular puede abortar con `ping()` durante la revisión o la impugnación.
6. Cada beneficiario ejecuta `claim(asset)`.

## Uso

```bash
npm install
npx hardhat compile
npx hardhat test

# Sepolia
cp .env.example .env   # completar RPC y clave de una wallet DE PRUEBA
npx hardhat run scripts/deploy.js --network sepolia
```

## Decisiones y límites

- **Cuenta inteligente:** el whitepaper contempla ERC-4337 o una arquitectura equivalente. Este MVP usa una bóveda propia (contrato de custodia + reglas en uno solo), sin abstracción de cuentas. Los fondos deben depositarse en la bóveda; una EOA no puede ser retirada por un contrato.
- Las transiciones por plazo requieren una transacción (cualquiera puede enviarla; luego se puede automatizar con un keeper).
- Sin redistribución de partes no reclamadas ni oráculo de fallecimiento.
- Tras `enableClaims()` los saldos se congelan; el ETH enviado después es rechazado.
- El redondeo por división entera puede dejar unos wei sin asignar.
- **No auditado.** No usar con fondos reales sin revisión de seguridad y asesoramiento legal.

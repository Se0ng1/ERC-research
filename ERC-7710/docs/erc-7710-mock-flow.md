# ERC-7710 Manager와 ERC-7579 Account 기능별 실행 흐름

ERC-7710은 `swap`, `token-transfer`, `claim` 같은 기능을 표준화된 권한 타입으로 분리합니다. 
이 구조에서는 User가 전체 지갑 권한을 넘기지 않고, 필요한 기능만 Operator에게 위임할 수 있습니다.

전체 흐름은 세 단계로 나뉩니다. 
1. EIP-7702 Account 사용에 동의 
2. mode 활성화에 동의 
3. 기능별 ERC-7710 delegation에 서명하면 Operator가 허용된 call을 실행

## 1. Setting

```mermaid
sequenceDiagram
    autonumber
    actor User as User
    participant Front as Front
    participant Wallet as User Wallet
    participant Account as User EOA / Account
    participant Impl as ERC-7579 Account Implementation
    participant Manager as ERC-7710 Manager
    participant Target as Feature Target

    User->>Front: ERC-7710 기능 위임 사용 시작
    Front->>Wallet: EIP-7702 Account 사용 요청<br/>Account implementation 지정
    Wallet-->>User: 7702 authorization 동의 화면 표시
    alt User가 동의하지 않음
        User--x Wallet: 거절
        Wallet--x Front: 설정 중단
    else User가 동의함
        User-->>Wallet: 7702 authorization 서명
        Wallet-->>Front: signed authorization 또는 tx hash 반환
        Front->>Account: 7702 authorization 포함 트랜잭션 전파
        Account->>Impl: ERC-7579 Account implementation 위임
        Account-->>Front: ERC-7579 Account 준비 완료
    end

    Front->>Account: ERC-7579 Account 확인
    alt Account 준비 실패
        Front--x User: 설정 중단
    else Account 준비 완료
        Front->>Manager: ERC-7710 Manager 준비
        Front->>Target: 기능별 target 준비<br/>swap, claim, token transfer

        Front-->>User: Account 구성 변경 동의 요청<br/>Manager 설치 + 기능별 mode 활성화
        alt User가 동의하지 않음
            User--x Front: 설정 중단
        else User가 동의함
            Front-->>User: Manager executor module 설치 요청
            User->>Account: installModule(2, Manager, initData)
            Account->>Manager: onInstall(initData)
            Account->>Account: executor module registry에 Manager 저장

            Front-->>User: 기능별 mode 등록 요청
            User->>Account: installExecutionMode(FEATURE_MODE)
            Account->>Account: supported mode registry에 FEATURE_MODE 저장
            Account-->>Front: Manager executor module + mode 등록 완료
        end
    end
```

## 2. Function mapping

| 기능 | permissionType | target | selector | 실행 결과 |
| --- | --- | --- | --- | --- |
| swap | `PERMISSION_TYPE_SWAP` | Swap target | `swapExactInput(address,address,uint256,uint256,address)` | token swap 실행 |
| claim | `PERMISSION_TYPE_CLAIM` | Claim target | `claim(address)` | claim 실행 |
| token transfer | `PERMISSION_TYPE_TOKEN_TRANSFER` | ERC-20 token 또는 transfer module | `transfer(address,uint256)` 등 | token transfer 실행 |

공통 ERC-7710 delegation 필드는 기능마다 동일합니다.

```text
delegator      = User의 ERC-7579 Account
operator       = 위임받은 실행자
permissionType = 기능별 권한 타입
target         = 기능별 호출 대상
selector       = 기능별 허용 selector
authority      = ROOT_AUTHORITY
signature      = User 또는 account owner의 EIP-712 서명
```

## 3. Swap

```mermaid
sequenceDiagram
    autonumber
    actor User as User
    actor Operator as Operator
    participant Front as Front
    participant Manager as ERC-7710 Manager
    participant Account as ERC-7579 Account
    participant Swap as Swap Target

    User->>Front: swap 권한 위임 시작
    Front-->>User: swap 권한 서명 요청<br/>permissionType=swap, target=SwapTarget, selector=swapExactInput
    User-->>Front: 서명된 ERC-7710 swap delegation 반환
    Front-->>Operator: permissionContext 전달

    Operator->>Front: swap 실행 데이터 구성<br/>SWAP_MODE + swapExactInput calldata
    Operator->>Manager: redeemDelegations(permissionContexts, modes, executionCallDatas)

    Manager->>Manager: tuple 길이 + operator 검증
    alt tuple 또는 operator가 유효하지 않음
        Manager--x Operator: revert
    else 기본 입력 유효
        Manager->>Manager: ERC-7710 swap delegation 검증<br/>permissionType + target + selector + 서명
        alt swap 권한 범위를 벗어남
            Manager--x Operator: revert
        else swap 권한 유효
            Manager->>Account: executeFromExecutor(SWAP_MODE, encoded swap call)
            alt Manager module 또는 mode가 미등록
                Account--x Manager: revert
            else 실행 가능
                Account->>Swap: swapExactInput(tokenIn, tokenOut, amountIn, minOut, Operator)
                Swap-->>Account: amountOut
                Account-->>Manager: execution result
                Manager-->>Operator: swap 실행 완료
            end
        end
    end
```

## 4. Claim

```mermaid
sequenceDiagram
    autonumber
    actor User as User
    actor Operator as Operator
    participant Front as Front
    participant Manager as ERC-7710 Manager
    participant Account as ERC-7579 Account
    participant Claim as Claim Target

    User->>Front: claim 권한 위임 시작
    Front-->>User: claim 권한 서명 요청<br/>permissionType=claim, target=ClaimTarget, selector=claim
    User-->>Front: 서명된 ERC-7710 claim delegation 반환
    Front-->>Operator: permissionContext 전달

    Operator->>Front: claim 실행 데이터 구성<br/>CLAIM_MODE + claim calldata
    Operator->>Manager: redeemDelegations(permissionContexts, modes, executionCallDatas)

    Manager->>Manager: tuple 길이 + operator 검증
    alt tuple 또는 operator가 유효하지 않음
        Manager--x Operator: revert
    else 기본 입력 유효
        Manager->>Manager: ERC-7710 claim delegation 검증<br/>permissionType + target + selector + 서명
        alt claim 권한 범위를 벗어남
            Manager--x Operator: revert
        else claim 권한 유효
            Manager->>Account: executeFromExecutor(CLAIM_MODE, encoded claim call)
            alt Manager module 또는 mode가 미등록
                Account--x Manager: revert
            else 실행 가능
                Account->>Claim: claim(Operator)
                Claim-->>Account: claim result
                Account-->>Manager: execution result
                Manager-->>Operator: claim 실행 완료
            end
        end
    end
```

## 5. Token Transfer

```mermaid
sequenceDiagram
    autonumber
    actor User as User
    actor Operator as Operator
    participant Front as Front
    participant Manager as ERC-7710 Manager
    participant Account as ERC-7579 Account
    participant Token as ERC-20 Token

    User->>Front: token-transfer 권한 위임 시작
    Front-->>User: token-transfer 권한 서명 요청<br/>permissionType=token-transfer, target=Token, selector=transfer
    User-->>Front: 서명된 ERC-7710 token-transfer delegation 반환
    Front-->>Operator: permissionContext 전달

    Operator->>Front: transfer 실행 데이터 구성<br/>TOKEN_TRANSFER_MODE + transfer calldata
    Operator->>Manager: redeemDelegations(permissionContexts, modes, executionCallDatas)

    Manager->>Manager: ERC-7710 token-transfer delegation 검증<br/>permissionType + target + selector + 서명
    alt token-transfer 권한 범위를 벗어남
        Manager--x Operator: revert
    else token-transfer 권한 유효
        Manager->>Account: executeFromExecutor(TOKEN_TRANSFER_MODE, encoded transfer call)
        alt Manager module 또는 mode가 미등록
            Account--x Manager: revert
        else 실행 가능
            Account->>Token: transfer(recipient, amount)
            Token-->>Account: transfer result
            Account-->>Manager: execution result
            Manager-->>Operator: token transfer 실행 완료
        end
    end
```

## 핵심 포인트

- 프론트의 첫 Account 관련 요청은 EIP-7702 Account 사용 동의입니다.
- 프론트가 User 지갑에 `installModule(2, manager, initData)` 트랜잭션을 요청해 ERC-7710 Manager를 executor module로 설치합니다.
- ERC-7579 Account에서는 실행에 사용할 mode도 지원 mode로 등록되어 있어야 합니다.
- 7702 동의는 Account 사용 준비에 대한 동의, 세팅 동의는 Account 구성 변경에 대한 동의, 기능별 위임은 ERC-7710 delegation 서명입니다.
- 문서의 `SWAP_MODE`, `CLAIM_MODE`, `TOKEN_TRANSFER_MODE`는 프론트 레벨 이름이며, 실제 on-chain 값은 ERC-7579 Account가 지원하는 encoded mode입니다.
- 권한을 위임받은 operator는 call 시점에 서명된 ERC-7710 delegation을 제출합니다.
- `permissionContexts`는 `Account -> Operator` 단일 delegation을 ABI 인코딩한 값입니다.
- ERC-7710 Manager는 ERC-7710 delegation의 `permissionType`, `target`, `selector`, EIP-712 서명, `ROOT_AUTHORITY`를 검증합니다.
- delegator가 EOA면 ECDSA로 검증하고, contract면 ERC-1271 `isValidSignature`로 검증합니다.
- 검증이 끝나면 ERC-7710 Manager가 ERC-7579 Account의 `executeFromExecutor`를 호출합니다.
- 실제 기능 call은 ERC-7579 Account가 수행합니다.

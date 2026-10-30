# Runbook de produção: perfis no card APPS-POR-BU

Estes passos são manuais. `profiles/**` está no `.forceignore`, então a pipeline não promove perfil.
Execute só depois que os metadados do card (apps ADV e SOL, `Arnone` e `Arnone_Atendimento` renomeados,
`Lead_STE`, PS com `applicationVisibilities`, `PS_Arnone_Gestao`) estiverem em produção pela promoção
`dev → uat → production`.

Quem executa: administrador de produção. Org: "Produção Grupo Arnone", Org Id `00Das00000FfJKhEAN`.

## Estado de produção antes do card (retrieve somente leitura em 25/10/2026)

| Perfil | App | Padrão | Visível |
|---|---|---|---|
| Admin (System Administrator) | `standard__LightningSales` | sim | sim |
| Admin | `Arnone`, `Arnone_Atendimento` | não | sim |
| Standard (Standard User) | `standard__LightningSales` | sim | sim |
| Standard | `Arnone`, `Arnone_Atendimento` | não | **sim** |
| Standard | `Inside_Sales`, `standard__Sales`, `standard__LightningSalesConsole`, `standard__HVSConsole`, `standard__Service`, `standard__Marketing`, `standard__EasyMarketing`, `standard__AppLauncher`, `standard__Chatter` | não | sim |

Hoje, no perfil Standard de produção, `Arnone` e `Arnone_Atendimento` estão **visíveis**. Os usuários
comerciais de produção chegam aos apps por esse perfil. **Esses dois apps só saem do perfil Standard
depois que os PS por BU (`PS_ADV_Comercial`, `PS_SOL_Comercial`, `PS_STE_Comercial`) estiverem
atribuídos aos usuários de produção (passo P6, fora deste card).** Se sair antes, os vendedores
ficam sem app.

Em produção, nenhum usuário tem `PS_Admin` (consulta de 25/10/2026). Os administradores veem `Arnone`
e `Arnone_Atendimento` pelo perfil. ADV e SOL só aparecem para eles com `PS_Admin` ou com o PS da BU.

## Passos

### R1. Conferir pré-requisitos
1. Setup → App Manager: existem "Arnone Advogados" (`ADV`), "Arnone Soluções" (`SOL`),
   "Arnone Gestão" (`Arnone`) e "Instituto STech" (`Arnone_Atendimento`).
2. Setup → Permission Sets: existe "Arnone Gestão — Acesso ao app" (`PS_Arnone_Gestao`).
3. Setup → Salesforce Mobile App: registre o estado de "Dynamic Forms and Dynamic Highlights Panel
   on Mobile" (em 25/10/2026 estava ligado, `DynamicFormsSettings.enableFormsOnMobile=true`).

### R2. Perfil Admin (System Administrator): app padrão
1. Setup → Profiles → System Administrator → Assigned Apps → Edit.
2. Marque "Default" em **Arnone Gestão** (`Arnone`). Mantenha "Visible" como está em todos os apps.
3. Salve. Confira que `standard__LightningSales` deixou de ser o padrão.

### R3. Perfil Standard (Standard User): app padrão
1. Setup → Profiles → Standard User → Assigned Apps → Edit.
2. Marque "Visible" e "Default" em **App Launcher** (`standard__AppLauncher`).
3. Se o Setup recusar o App Launcher como padrão, use **Chatter** (`standard__Chatter`) e registre.
4. Salve.

### R4. Perfil Standard: tirar visibilidade dos apps padrão
No mesmo "Assigned Apps" do Standard User, desmarque "Visible" em:
- `Inside_Sales`
- `standard__LightningSales` (Sales, Lightning)
- `standard__LightningSalesConsole` (Sales Console)
- `standard__Sales` (Sales, Classic)
- `standard__HVSConsole`
- `standard__Service`
- `standard__Marketing`
- `standard__EasyMarketing`

Salve.

### R5. Perfil Standard: tirar `Arnone` e `Arnone_Atendimento` (só depois do P6)
**Pré-condição:** P6 concluído (OWD, papéis e PS por BU atribuídos aos usuários de produção). Confira com:

```
SELECT Assignee.Name, PermissionSet.Name FROM PermissionSetAssignment
WHERE PermissionSet.Name IN ('PS_ADV_Comercial','PS_SOL_Comercial','PS_STE_Comercial')
   OR PermissionSetGroup.DeveloperName = 'PSG_SOL_Comercial'
```

Cada usuário comercial ativo precisa aparecer com o PS ou o PSG da sua BU.

Depois, em Standard User → Assigned Apps, desmarque "Visible" em **Arnone Gestão** (`Arnone`) e
**Instituto STech** (`Arnone_Atendimento`). Salve.

### R6. Verificação
1. Faça o retrieve (somente leitura) de `Profile:Admin` e `Profile:Standard` junto com as
   CustomApplications acima e confira as `applicationVisibilities`:
   - Admin: `Arnone` default=true.
   - Standard: `standard__AppLauncher` (ou `standard__Chatter`) default=true; os apps de R4 com
     visible=false; depois do R5, também `Arnone` e `Arnone_Atendimento` com visible=false.
2. "Login As" com um vendedor de cada BU: o App Launcher mostra só o app da BU dele.

## Rollback
Em Assigned Apps, volte cada perfil ao estado da tabela "antes": `standard__LightningSales` como
padrão e "Visible" marcado em todos os apps listados.

## Referência na sandbox
Na ArnoneDev, os mesmos passos foram aplicados por pacote Metadata API só com
`<applicationVisibilities>` (deploy `0Afbe00000BiOQ5CAN`, 25/10/2026). O pacote está no scratchpad do
card e não vai para produção: em produção os passos são manuais, conforme acima.

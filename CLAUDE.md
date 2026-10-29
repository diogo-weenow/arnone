# CLAUDE.md — Grupo Arnone (repo SFDX)

Org multi-BU: ADV (Arnone Advogados), SOL (Arnone Soluções), STE (Instituto STech), além de ESG e SCO.
Sandbox de desenvolvimento: alias `ArnoneDev`. Leia esta página antes de criar campo, página ou atribuição.

## Convenção de campos e páginas por BU

1. **Prefixo de BU obrigatório** em campo novo: `ADV_`, `SOL_`, `STE_`. Campo sem prefixo só quando usado por 2+ BUs, e com decisão registrada do arquiteto.
2. **Campo de BU entra só na FlexiPage da BU** (`<Objeto>_<BU>`, ex.: `Opportunity_ADV`), em Field Sections (Dynamic Forms). Nunca no page layout base, que fica só com campos comuns.
3. **Seções** com o nome `<Tema> — <BU>` (ex.: "Precificação e Proposta — Arnone Advogados").
4. **Indicadores** (fórmulas, durações, contadores) ficam somente leitura numa aba **Indicadores** da página da BU.
5. **Visibilidade de seção** por `StageName` (Opportunity) ou `Status` (Lead). Dados de decisão: visibilidade cumulativa (aparece a partir da etapa e continua depois).
   - Visibility rule de picklist não aceita "≠ vazio": enumere os valores com OR e atualize a regra quando o picklist ganhar valor.
   - Regra com um só filtro não leva `booleanFilter`.
6. **Campo exigido por VR na transição** vira key field do Path da etapa de destino.
7. **Obrigatoriedade condicional só em VR.** Nada de `required` na página para campo de BU (só os obrigatórios do padrão: Name, StageName, CloseDate etc.).
8. **Campo criado pela UI nunca "visível para todos os perfis".** FLS só no PS da BU, por DML cirúrgico em `FieldPermissions` ou partindo da versão da org.
9. **Atribuição de página só por metadado** (`profileActionOverrides` no app, por app + RT + perfil + formFactor). Faça retrieve antes e compare a contagem de `actionOverrides`/`profileActionOverrides` antes e depois. Nunca "Activation" no App Builder.
10. **RT novo de BU** exige: FlexiPage + Path + compact layout (`compactLayoutAssignment` no RT) + atribuições desktop **e** celular + Dynamic Actions.
11. **Mobile sempre:** Dynamic Forms on Mobile está ligado (`DynamicFormsSettings.enableFormsOnMobile`). Atribua `Small` em todo app que declara `<formFactors>Small</formFactors>`; com Dynamic Actions, `enableActionsInNative=true`.

## Armadilhas conhecidas

- **Deploy de PermissionSet substitui `fieldPermissions`.** Cards paralelos se apagam em silêncio. Parta sempre da versão da org ou use DML cirúrgico.
- **Deploy SOL com Apex:** desagendar os 4 schedulers SOL → deploy → reagendar. Sem Apex no pacote, não mexa nos schedulers; confirme os 4 em `WAITING` no fim.
- **Nunca deploye o `force-app` inteiro.** Use manifesto exclusivo do card (`manifest/package-<card>.xml`), confira o pacote antes e faça `Set-Location` no mesmo comando do deploy.
- **Filho de objeto (RecordType, CompactLayout):** o `convert` gera o `.object` com atributos do objeto pai. Para não tocar o CustomObject, deploye por `--metadata-dir` com o `.object` reduzido aos filhos do pacote.
- **Retrieve de RecordType sozinho** não traz os picklists de campos custom. Para comparar com a org, inclua os `CustomField` dos picklists no retrieve.
- **Cruze sempre com a org:** describe esconde campo sem FLS para o usuário que consulta.
- **Gate de PR:** nenhum PR sem pacote de validação revisado e a frase literal `AUTORIZADO ABRIR PR`.

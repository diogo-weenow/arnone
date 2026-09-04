/**
 * CLICKUP-9424 — Card 13: EVIDÊNCIA PÓS-COMMIT do histórico de proprietário e
 * do acesso em nível de REGISTRO para vendedor e gestor.
 *
 * POR QUE ESTE SCRIPT EXISTE
 *   1. `OpportunityFieldHistory` só é materializado no COMMIT da transação.
 *      Dentro de um teste Apex (ou de uma execução anônima que faz a troca e
 *      consulta no mesmo runtime) as linhas ainda não existem. Logo, os valores
 *      `OldValue`/`NewValue` NÃO podem ser afirmados por teste automatizado —
 *      só aqui, lendo trocas já confirmadas.
 *   2. O acesso em nível de registro do GESTOR não é entregue por este card:
 *      `PS_SOL_Distribuicao_Admin` não concede `objectPermissions` de
 *      Opportunity (só do singleton `SOL_Distribuicao_Estado__c`). Ele vem do
 *      perfil + hierarquia de papéis já configurados na org. Este script mede
 *      esse acesso REAL com `UserRecordAccess`, sem criar permission set
 *      sintético nenhum.
 *
 * COMO USAR
 *   `sf apex run --file scripts/apex/clickup-9424-evidencia-historico-acesso.apex --target-org <alias>`
 *   Somente LEITURA — nenhum registro é criado, alterado ou excluído.
 */

// ------------------------------------------------- 1. contexto
System.debug(LoggingLevel.ERROR, '=== CLICKUP-9424 · EVIDÊNCIA DE HISTÓRICO E ACESSO ===');
System.debug(LoggingLevel.ERROR, '[1] Executado por ' + UserInfo.getUserName()
  + ' | histórico de Opportunity habilitado: '
  + Schema.getGlobalDescribe().containsKey('opportunityfieldhistory'));

// ------------------------------------------------- 2. o que o PS do gestor concede
Integer oppNoPsAdmin = [
  SELECT COUNT()
  FROM ObjectPermissions
  WHERE Parent.Name = 'PS_SOL_Distribuicao_Admin' AND SobjectType = 'Opportunity'
];
System.debug(LoggingLevel.ERROR, '[2] objectPermissions de Opportunity em PS_SOL_Distribuicao_Admin: '
  + oppNoPsAdmin + ' (esperado 0 — o acesso de registro do gestor NÃO vem deste card)');
for (ObjectPermissions op : [
  SELECT SobjectType, PermissionsRead, PermissionsViewAllRecords
  FROM ObjectPermissions
  WHERE Parent.Name = 'PS_SOL_Distribuicao_Admin'
]) {
  System.debug(LoggingLevel.ERROR, '[2]   concede objeto: ' + op.SobjectType
    + ' read=' + op.PermissionsRead + ' viewAll=' + op.PermissionsViewAllRecords);
}

// ------------------------------------------------- 3. histórico real das trocas
Set<Id> reatribuidas = new Map<Id, Opportunity>([
  SELECT Id
  FROM Opportunity
  WHERE SOL_Status_Reatribuicao_Prazo__c = 'Reatribuido'
]).keySet();
System.debug(LoggingLevel.ERROR, '[3] Oportunidades reatribuídas por prazo: ' + reatribuidas.size());

List<OpportunityFieldHistory> hist = [
  SELECT OpportunityId, Field, OldValue, NewValue, CreatedDate
  FROM OpportunityFieldHistory
  WHERE OpportunityId IN :reatribuidas AND Field = 'Owner'
  ORDER BY CreatedDate DESC
  LIMIT 30
];
System.debug(LoggingLevel.ERROR, '[3] Linhas de histórico Field=Owner: ' + hist.size());
for (OpportunityFieldHistory h : hist) {
  System.debug(LoggingLevel.ERROR, '[3]   ' + h.OpportunityId
    + ' | OldValue=' + h.OldValue + ' -> NewValue=' + h.NewValue + ' @ ' + h.CreatedDate);
}

// ------------------------------------------------- 4. acesso em nível de registro
// Vendedor = proprietário atual da Oportunidade. Gestor = usuário ATIVO acima
// dele na hierarquia de papéis (papel pai), medido com UserRecordAccess.
if (reatribuidas.isEmpty()) {
  System.debug(LoggingLevel.ERROR, '[4] Sem Oportunidade reatribuída: rode o E2E antes.');
  return;
}

Id alvo = new List<Id>(reatribuidas)[0];
Opportunity oppAlvo = [
  SELECT Id, Name, OwnerId, Owner.Name, Owner.UserRoleId, Owner.UserRole.Name,
         Owner.UserRole.ParentRoleId, Owner.Profile.Name
  FROM Opportunity
  WHERE Id = :alvo
];
System.debug(LoggingLevel.ERROR, '[4] Oportunidade alvo: ' + oppAlvo.Id
  + ' | dono=' + oppAlvo.Owner.Name + ' (' + oppAlvo.OwnerId + ')'
  + ' | papel=' + oppAlvo.Owner.UserRole.Name + ' | perfil=' + oppAlvo.Owner.Profile.Name);

// Vendedor (dono) — acesso garantido pela propriedade do registro.
for (UserRecordAccess ura : [
  SELECT RecordId, HasReadAccess, HasEditAccess, MaxAccessLevel
  FROM UserRecordAccess
  WHERE UserId = :oppAlvo.OwnerId AND RecordId = :alvo
]) {
  System.debug(LoggingLevel.ERROR, '[4] VENDEDOR (dono) ' + oppAlvo.Owner.Name
    + ': HasReadAccess=' + ura.HasReadAccess + ' HasEditAccess=' + ura.HasEditAccess
    + ' MaxAccessLevel=' + ura.MaxAccessLevel);
}

// Gestor — quem está ACIMA do dono na hierarquia de papéis (papel pai e avô).
Set<Id> papeisAcima = new Set<Id>();
Id papelAtual = oppAlvo.Owner.UserRole.ParentRoleId;
Map<Id, UserRole> todosPapeis = new Map<Id, UserRole>([SELECT Id, Name, ParentRoleId FROM UserRole]);
Integer guarda = 0;
while (papelAtual != null && guarda < 10) {
  papeisAcima.add(papelAtual);
  papelAtual = todosPapeis.get(papelAtual) == null ? null : todosPapeis.get(papelAtual).ParentRoleId;
  guarda++;
}
System.debug(LoggingLevel.ERROR, '[4] Papéis ACIMA do dono na hierarquia: ' + papeisAcima.size());

// Candidatos a gestor: (a) quem está em papel superior ao do dono; (b) quem
// está nos papéis de supervisão da jornada SOL ("Coordenação"/"Diretoria"),
// que é a persona real de gestor independente de quem ficou com esta Opp.
Set<Id> papeisGestor = new Set<Id>(papeisAcima);
for (UserRole r : todosPapeis.values()) {
  if (
    r.Name != null &&
    (r.Name.containsIgnoreCase('Coordenação Arnone Soluções') ||
    r.Name.containsIgnoreCase('Diretoria Grupo Arnone'))
  ) {
    papeisGestor.add(r.Id);
  }
}

List<User> gestores = [
  SELECT Id, Name, UserRole.Name, Profile.Name, Profile.PermissionsViewAllData
  FROM User
  WHERE IsActive = true AND UserRoleId IN :papeisGestor
  LIMIT 10
];
System.debug(LoggingLevel.ERROR, '[4] Candidatos a GESTOR (papel superior ao dono + supervisão SOL): '
  + gestores.size());
if (gestores.isEmpty()) {
  System.debug(LoggingLevel.ERROR, '[4] Nenhum usuário ativo nesses papéis — o acesso do gestor '
    + 'dependeria de "Ver todos os dados" no perfil ou de regras de compartilhamento.');
}
for (User g : gestores) {
  for (UserRecordAccess ura : [
    SELECT RecordId, HasReadAccess, HasEditAccess, MaxAccessLevel
    FROM UserRecordAccess
    WHERE UserId = :g.Id AND RecordId = :alvo
  ]) {
    System.debug(LoggingLevel.ERROR, '[4] GESTOR ' + g.Name
      + ' | papel=' + g.UserRole.Name + ' | perfil=' + g.Profile.Name
      + ' | ViewAllData(perfil)=' + g.Profile.PermissionsViewAllData
      + ' -> HasReadAccess=' + ura.HasReadAccess
      + ' HasEditAccess=' + ura.HasEditAccess
      + ' MaxAccessLevel=' + ura.MaxAccessLevel);
  }
}

// Também mede um VENDEDOR real da BU (papel "Comercial Arnone Soluções"),
// para deixar claro de onde vem — ou não vem — o acesso de quem não é dono.
for (User v : [
  SELECT Id, Name, UserRole.Name, Profile.Name, Profile.PermissionsViewAllData
  FROM User
  WHERE IsActive = true AND UserRole.Name = 'Comercial Arnone Soluções' AND Id != :oppAlvo.OwnerId
  LIMIT 3
]) {
  for (UserRecordAccess ura : [
    SELECT RecordId, HasReadAccess, MaxAccessLevel
    FROM UserRecordAccess
    WHERE UserId = :v.Id AND RecordId = :alvo
  ]) {
    System.debug(LoggingLevel.ERROR, '[4] VENDEDOR NÃO-DONO ' + v.Name
      + ' | papel=' + v.UserRole.Name + ' | perfil=' + v.Profile.Name
      + ' | ViewAllData(perfil)=' + v.Profile.PermissionsViewAllData
      + ' -> HasReadAccess=' + ura.HasReadAccess + ' MaxAccessLevel=' + ura.MaxAccessLevel);
  }
}

// ------------------------------------------------- 5. FLS declarada nos 2 PS
Set<String> campos = new Set<String>{
  'Opportunity.SOL_Data_Inicio_Ciclo_Comercial__c',
  'Opportunity.SOL_Prazo_Total_Comercial__c',
  'Opportunity.SOL_Data_Reatribuicao_Prazo__c',
  'Opportunity.SOL_Motivo_Reatribuicao_Prazo__c',
  'Opportunity.SOL_Qtd_Reatribuicoes_Prazo__c',
  'Opportunity.SOL_Status_Reatribuicao_Prazo__c'
};
for (String ps : new List<String>{ 'PS_SOL_Comercial', 'PS_SOL_Distribuicao_Admin' }) {
  Integer lidos = 0;
  Integer editaveis = 0;
  for (FieldPermissions fp : [
    SELECT Field, PermissionsRead, PermissionsEdit
    FROM FieldPermissions
    WHERE Parent.Name = :ps AND SobjectType = 'Opportunity' AND Field IN :campos
  ]) {
    if (fp.PermissionsRead) {
      lidos++;
    }
    if (fp.PermissionsEdit) {
      editaveis++;
    }
  }
  System.debug(LoggingLevel.ERROR, '[5] ' + ps + ': campos legíveis=' + lidos
    + '/6 | editáveis=' + editaveis + ' (esperado 0 — campos técnicos)');
}

System.debug(LoggingLevel.ERROR, '=== FIM ===');

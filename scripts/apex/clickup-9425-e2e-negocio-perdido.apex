/**
 * CLICKUP-9425 — Card 14: E2E REAL do encerramento automático de tarefas ao
 * perder o negócio da Arnone Soluções.
 *
 * Roda contra a org com os Flows ATIVOS: cada perda abaixo é feita pela via
 * normal (update do Lead / da Oportunidade) e o cancelamento das tarefas é
 * consequência da automação, não de chamada direta ao serviço.
 *
 * COBERTURA
 *   [1] Lead perdido antes da conversão — Recuperação Tributária e ART 360,
 *       com tarefa classificada + tarefa MANUAL sem tipo.
 *   [2] Oportunidade perdida — os dois produtos, com tarefa de Fechamento.
 *   [3] GANHO × PERDIDO: precedência sobre o CLICKUP-9423.
 *   [4] Opt-out isolado: motivo próprio, sem flag de perda.
 *   [5] Bloqueio das automações posteriores à perda (Grupo B).
 *   [6] Acesso em nível de REGISTRO ao histórico do cancelamento
 *       (UserRecordAccess), separando FLS de compartilhamento/perfil.
 *
 * Execução: `sf apex run --file scripts/apex/clickup-9425-e2e-negocio-perdido.apex --target-org <alias>`
 * Cria dados de teste próprios (prefixo E2E9425-). NÃO executa migração.
 */
String tg = 'E2E9425-' + Datetime.now().getTime();
Id rtLead = Lead.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('SOL').getRecordTypeId();
Id rtOpp = Opportunity.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('SOL').getRecordTypeId();
Date hoje = Date.today();
String RT = 'Recuperação Tributária';
String ART = 'ART 360';
String MOTIVO = 'Negócio perdido';

System.debug(LoggingLevel.ERROR, '=== CLICKUP-9425 · E2E NEGÓCIO PERDIDO (' + tg + ') ===');

// ------------------------------------------------------------------ fixtures
Id novoLead(String produto, String t2) {
  Lead l = new Lead(RecordTypeId = rtLead, LastName = 'Perda ' + t2, Company = 'C ' + t2,
    Status = 'Captação - Contato', CNPJ__c = '11222333000181', SOL_Produto_Interesse__c = produto);
  Database.DMLOptions o = new Database.DMLOptions();
  o.duplicateRuleHeader.allowSave = true;
  Database.insert(l, o);
  return l.Id;
}

Id novaOpp(String produto, String etapa, String t2) {
  Account a = new Account(Name = 'Conta ' + t2);
  insert a;
  Opportunity o = new Opportunity(Name = 'Op ' + t2, AccountId = a.Id, RecordTypeId = rtOpp,
    CloseDate = hoje.addDays(60), StageName = 'Diagnóstico', SOL_Produto_Negocio__c = produto,
    SOL_ECAC_Consulta_Realizada__c = true, SOL_ECAC_Data_Consulta__c = hoje,
    SOL_ECAC_Resultado__c = 'Valor a recuperar', SOL_Valor_Recuperavel__c = 1000,
    SOL_Apresentacao_Realizada__c = true, SOL_Data_Apresentacao__c = hoje,
    SOL_Resultado_Apresentacao__c = 'Sucesso', SOL_Percentual_Comissao__c = 20,
    SOL_Valor_Servico__c = 5000);
  insert o;
  if (etapa != 'Diagnóstico') {
    update new Opportunity(Id = o.Id, StageName = 'Negociação');
    if (etapa != 'Negociação') {
      update new Opportunity(Id = o.Id, StageName = etapa);
    }
  }
  return o.Id;
}

Id tarefa(Id whoId, Id whatId, String tipo, String t2) {
  Task t = new Task(Subject = 'T ' + t2, OwnerId = UserInfo.getUserId(), Status = 'Open',
    ActivityDate = hoje.addDays(5), SOL_Tipo_Tarefa__c = tipo);
  if (whoId != null) { t.WhoId = whoId; }
  if (whatId != null) { t.WhatId = whatId; }
  insert t;
  return t.Id;
}

String estadoTask(Id taskId) {
  Task t = [SELECT Status, IsClosed, SOL_Tipo_Tarefa__c, SOL_Motivo_Cancelamento__c,
                   SOL_Cancelada_Por_Perda__c, SOL_Encerrado_Pela_Oportunidade__c
            FROM Task WHERE Id = :taskId];
  return 'status=' + t.Status + ' fechada=' + t.IsClosed
    + ' tipo=' + (t.SOL_Tipo_Tarefa__c == null ? '(manual/sem tipo)' : t.SOL_Tipo_Tarefa__c)
    + ' motivo=' + t.SOL_Motivo_Cancelamento__c
    + ' porPerda=' + t.SOL_Cancelada_Por_Perda__c
    + ' encerradoPelaOpp=' + t.SOL_Encerrado_Pela_Oportunidade__c;
}

// ------------------------------------------------- [1] LEAD PERDIDO (RT/ART)
Map<String, Id> leadPorProduto = new Map<String, Id>();
Map<String, Id> tipadaPorProduto = new Map<String, Id>();
Map<String, Id> manualPorProduto = new Map<String, Id>();
for (String prod : new List<String>{ RT, ART }) {
  Id lid = novoLead(prod, tg + '-' + prod.left(3));
  leadPorProduto.put(prod, lid);
  tipadaPorProduto.put(prod, tarefa(lid, null, 'Contato', tg));
  manualPorProduto.put(prod, tarefa(lid, null, null, tg + '-manual'));
}
for (String prod : leadPorProduto.keySet()) {
  update new Lead(Id = leadPorProduto.get(prod), Status = 'Desqualificado',
    SOL_Motivo_Desqualificacao__c = MOTIVO, SOL_Opt_Out__c = false);
}
for (String prod : leadPorProduto.keySet()) {
  Lead l = [SELECT Status, SOL_Motivo_Desqualificacao__c, SOL_Opt_Out__c, IsConverted
            FROM Lead WHERE Id = :leadPorProduto.get(prod)];
  System.debug(LoggingLevel.ERROR, '[1] LEAD ' + prod + ': status=' + l.Status
    + ' motivo=' + l.SOL_Motivo_Desqualificacao__c + ' optOut=' + l.SOL_Opt_Out__c
    + ' convertido=' + l.IsConverted);
  System.debug(LoggingLevel.ERROR, '[1]   tarefa classificada -> ' + estadoTask(tipadaPorProduto.get(prod)));
  System.debug(LoggingLevel.ERROR, '[1]   tarefa MANUAL       -> ' + estadoTask(manualPorProduto.get(prod)));
}

// ------------------------------------------ [2] OPORTUNIDADE PERDIDA (RT/ART)
Map<String, Id> oppPorProduto = new Map<String, Id>();
Map<String, Id> fechPorProduto = new Map<String, Id>();
Map<String, Id> manualOppPorProduto = new Map<String, Id>();
for (String prod : new List<String>{ RT, ART }) {
  Id oid = novaOpp(prod, 'Negociação', tg + '-opp-' + prod.left(3));
  oppPorProduto.put(prod, oid);
  fechPorProduto.put(prod, tarefa(null, oid, 'Fechamento', tg));
  manualOppPorProduto.put(prod, tarefa(null, oid, null, tg + '-manual'));
}
for (String prod : oppPorProduto.keySet()) {
  update new Opportunity(Id = oppPorProduto.get(prod), StageName = 'Perdido',
    SOL_Motivo_Perda__c = 'Sem retorno');
}
for (String prod : oppPorProduto.keySet()) {
  Opportunity o = [SELECT StageName, IsClosed FROM Opportunity WHERE Id = :oppPorProduto.get(prod)];
  System.debug(LoggingLevel.ERROR, '[2] OPP ' + prod + ': etapa=' + o.StageName + ' fechada=' + o.IsClosed);
  System.debug(LoggingLevel.ERROR, '[2]   tarefa Fechamento -> ' + estadoTask(fechPorProduto.get(prod)));
  System.debug(LoggingLevel.ERROR, '[2]   tarefa MANUAL     -> ' + estadoTask(manualOppPorProduto.get(prod)));
}

// -------------------------------------------------- [3] GANHO x PERDIDO (9423)
Id oppGanha = novaOpp(RT, 'Negociação', tg + '-ganho');
Id fechGanho = tarefa(null, oppGanha, 'Fechamento', tg + '-g');
Id outraGanho = tarefa(null, oppGanha, 'Contato', tg + '-g2');
update new Opportunity(Id = oppGanha, StageName = 'Ganho');
System.debug(LoggingLevel.ERROR, '[3] GANHO — precedência do CLICKUP-9423 preservada:');
System.debug(LoggingLevel.ERROR, '[3]   Fechamento     -> ' + estadoTask(fechGanho)
  + '   (esperado: Completed + encerradoPelaOpp=true, SEM porPerda)');
System.debug(LoggingLevel.ERROR, '[3]   outra aberta   -> ' + estadoTask(outraGanho)
  + '   (esperado: Open — fora do escopo do 9423)');
System.debug(LoggingLevel.ERROR, '[3] PERDIDO -> Fechamento fica Cancelada (ver passo [2]).');

// ------------------------------------------------------------ [4] OPT-OUT
Id leadOptOut = novoLead(RT, tg + '-oo');
Id tarefaOptOut = tarefa(leadOptOut, null, 'Contato', tg + '-oo');
SOLDistribuicaoService.registrarOptOut(new List<Id>{ leadOptOut });
Lead lo = [SELECT Status, SOL_Motivo_Desqualificacao__c, SOL_Opt_Out__c FROM Lead WHERE Id = :leadOptOut];
System.debug(LoggingLevel.ERROR, '[4] OPT-OUT isolado: status=' + lo.Status
  + ' motivo=' + lo.SOL_Motivo_Desqualificacao__c + ' optOut=' + lo.SOL_Opt_Out__c
  + '   (esperado motivo "Opt-out", NÃO "Negócio perdido")');
System.debug(LoggingLevel.ERROR, '[4]   tarefa -> ' + estadoTask(tarefaOptOut)
  + '   (esperado motivo=Opt-out, porPerda=false)');

// ------------------------------- [5] BLOQUEIO DAS AUTOMAÇÕES APÓS A PERDA
Id leadBloqueio = leadPorProduto.get(RT);
Integer tarefasAntes = [SELECT COUNT() FROM Task WHERE WhoId = :leadBloqueio];
SOLDistribuicaoService.Resultado rDist = SOLDistribuicaoService.distribuir(new List<Id>{ leadBloqueio });
SOLDistribuicaoService.ResultadoReatribuicao rReat = SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ leadBloqueio });
SOLDistribuicaoService.ResultadoContatoEfetivado rCont = SOLDistribuicaoService.registrarContatoEfetivado(new List<Id>{ leadBloqueio });
SOLReuniaoComercialService.ResultadoReuniaoComercial rReu = SOLReuniaoComercialService.criarTarefaReuniao(new List<Id>{ leadBloqueio });
SOLProcuracaoAcompanhamentoService.ResultadoAcompanhamento rProc = SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(new List<Id>{ leadBloqueio });
Integer tarefasDepois = [SELECT COUNT() FROM Task WHERE WhoId = :leadBloqueio];
System.debug(LoggingLevel.ERROR, '[5] LEAD perdido — reprocessamento do Grupo B:');
System.debug(LoggingLevel.ERROR, '[5]   distribuir: distribuidos=' + rDist.distribuidos + ' ignorados=' + rDist.ignorados);
System.debug(LoggingLevel.ERROR, '[5]   reatribuirPorFaltaDeContato: reatribuidos=' + rReat.reatribuidos + ' ignorados=' + rReat.ignorados);
System.debug(LoggingLevel.ERROR, '[5]   registrarContatoEfetivado: sinalizados=' + rCont.leadsSinalizados + ' ignorados=' + rCont.ignorados);
System.debug(LoggingLevel.ERROR, '[5]   criarTarefaReuniao: criadas=' + rReu.tarefasCriadas + ' ignorados=' + rReu.ignorados);
System.debug(LoggingLevel.ERROR, '[5]   criarTarefaAcompanhamento: criadas=' + rProc.tarefasCriadas + ' ignorados=' + rProc.ignorados);
System.debug(LoggingLevel.ERROR, '[5]   tarefas do Lead antes=' + tarefasAntes + ' depois=' + tarefasDepois
  + ' | abertas agora=' + [SELECT COUNT() FROM Task WHERE WhoId = :leadBloqueio AND IsClosed = false]);

Id oppBloqueio = oppPorProduto.get(RT);
SOLAcompanhamentoCalculoService.ResultadoAcompanhamento rAc = SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(new List<Id>{ oppBloqueio });
SOLPrazoTotalService.ResultadoPrazoTotal rPz = SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppBloqueio });
System.debug(LoggingLevel.ERROR, '[5] OPP perdida — acompanhamento criadas=' + rAc.tarefasCriadas
  + ' | prazo total reatribuidas=' + rPz.reatribuidas + ' ignoradas=' + rPz.ignoradas
  + ' | abertas agora=' + [SELECT COUNT() FROM Task WHERE WhatId = :oppBloqueio AND IsClosed = false]);

// ------------------------------------------------ [6] ACESSO AO HISTÓRICO
// O histórico do cancelamento vive no PRÓPRIO registro (Status + motivo + flag);
// nada é apagado. O acesso em nível de registro NÃO vem deste card: mede-se com
// UserRecordAccess sobre usuários REAIS, separando FLS de compartilhamento.
Integer taskNoPsComercial = [
  SELECT COUNT() FROM ObjectPermissions
  WHERE Parent.Name = 'PS_SOL_Comercial' AND SobjectType = 'Task'
];
System.debug(LoggingLevel.ERROR, '[6] objectPermissions de Task em PS_SOL_Comercial: ' + taskNoPsComercial
  + ' (esperado 0 — a visibilidade de registro vem de perfil/hierarquia, não do card)');
for (String ps : new List<String>{ 'PS_SOL_Comercial', 'PS_SOL_Distribuicao_Admin' }) {
  for (FieldPermissions fp : [
    SELECT Field, PermissionsRead, PermissionsEdit FROM FieldPermissions
    WHERE Parent.Name = :ps AND SobjectType = 'Task' AND Field = 'Task.SOL_Cancelada_Por_Perda__c'
  ]) {
    System.debug(LoggingLevel.ERROR, '[6] FLS ' + ps + ' -> ' + fp.Field
      + ' read=' + fp.PermissionsRead + ' edit=' + fp.PermissionsEdit + ' (esperado read=true edit=false)');
  }
}
Id taskAlvo = manualOppPorProduto.get(RT);
for (UserRecordAccess ura : [
  SELECT RecordId, HasReadAccess, HasEditAccess, MaxAccessLevel
  FROM UserRecordAccess WHERE UserId = :UserInfo.getUserId() AND RecordId = :taskAlvo
]) {
  System.debug(LoggingLevel.ERROR, '[6] DONO da tarefa (' + UserInfo.getName() + '): HasReadAccess='
    + ura.HasReadAccess + ' MaxAccessLevel=' + ura.MaxAccessLevel);
}
for (User v : [
  SELECT Id, Name, UserRole.Name, Profile.Name, Profile.PermissionsViewAllData
  FROM User WHERE IsActive = true AND UserRole.Name = 'Comercial Arnone Soluções'
    AND Id != :UserInfo.getUserId() LIMIT 2
]) {
  for (UserRecordAccess ura : [
    SELECT RecordId, HasReadAccess, MaxAccessLevel
    FROM UserRecordAccess WHERE UserId = :v.Id AND RecordId = :taskAlvo
  ]) {
    System.debug(LoggingLevel.ERROR, '[6] NÃO-DONO ' + v.Name + ' | papel=' + v.UserRole.Name
      + ' | perfil=' + v.Profile.Name + ' | ViewAllData=' + v.Profile.PermissionsViewAllData
      + ' -> HasReadAccess=' + ura.HasReadAccess + ' MaxAccessLevel=' + ura.MaxAccessLevel);
  }
}

System.debug(LoggingLevel.ERROR, '=== E2E 9425 FIM ===');

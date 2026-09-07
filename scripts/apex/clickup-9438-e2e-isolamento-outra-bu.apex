/**
 * CLICKUP-9438 — E2E REAL do ISOLAMENTO: uma Oportunidade de OUTRA BU, com um
 * produto da Arnone Soluções preenchido via API, perdida pelo processo daquela
 * BU.
 *
 * O QUE ESTE E2E DEFENDE: o Flow before-save SOL_Marco_Perda_Oportunidade
 * carimba o contador de transições `SOL_Qtd_Perdas__c`. Se o recorte dele fosse
 * só o produto, bastaria alguém preencher "Recuperação Tributária" ou "ART 360"
 * numa Oportunidade de outra unidade para a automação da Arnone Soluções passar
 * a escrever nela. O recorte exige as TRÊS condições juntas: Record Type SOL,
 * produto no escopo e transição REAL para "Perdido".
 *
 * VERIFICA, contra a org real e com os Flows ATIVOS, que a Oportunidade de
 * outra BU:
 *   - é perdida normalmente pelo processo da unidade dela;
 *   - NÃO tem `SOL_Qtd_Perdas__c` incrementado;
 *   - NÃO gera `SOL_Evento_Jornada__c`;
 *   - NÃO tem tarefas nem outros dados alterados pela automação SOL.
 * E, como contraprova, que a MESMA perda no Record Type SOL conta.
 *
 * O Record Type usado como "outra BU" é STE_Telecom, que tem etapa "Perdido" no
 * funil próprio e está disponível para o usuário que roda o script. Trocar por
 * outro Record Type ativo com "Perdido" não muda o que é verificado.
 *
 * Execução (independente dos demais E2E; não depende de ordem):
 *   sf apex run --file scripts/apex/clickup-9438-e2e-isolamento-outra-bu.apex --target-org <alias>
 *
 * Cria dados próprios com o prefixo E2E_9438 e os REMOVE ao final — o cenário
 * negativo não deve poluir o relatório da Arnone Soluções.
 */
String TAG = 'E2E_9438-iso-' + Datetime.now().getTime();
String RT_PRODUTO = 'Recuperação Tributária';
Id rtOutraBU = Opportunity.SObjectType.getDescribe()
  .getRecordTypeInfosByDeveloperName()
  .get('STE_Telecom')
  .getRecordTypeId();
Id rtSOL = Opportunity.SObjectType.getDescribe()
  .getRecordTypeInfosByDeveloperName()
  .get('SOL')
  .getRecordTypeId();
Date hoje = Date.today();

Integer falhas = 0;
void ok(String titulo, Boolean condicao, String detalhe) {
  System.debug(
    LoggingLevel.ERROR,
    (condicao ? '  OK      ' : '  FALHOU  ') + titulo + ' | ' + detalhe
  );
  if (!condicao) {
    falhas++;
  }
}

System.debug(LoggingLevel.ERROR, '=== CLICKUP-9438 · E2E ISOLAMENTO DE OUTRA BU (' + TAG + ') ===');

Account a = new Account(Name = 'Conta ' + TAG);
insert a;

// ---------------------------------------------- [1] CENÁRIO NEGATIVO
Opportunity outraBU = new Opportunity(
  Name = 'Op outra BU ' + TAG,
  AccountId = a.Id,
  RecordTypeId = rtOutraBU,
  CloseDate = hoje.addDays(30),
  StageName = 'Pré-Matrícula',
  // O vetor do problema: produto da Arnone Soluções num registro de outra BU.
  SOL_Produto_Negocio__c = RT_PRODUTO
);
insert outraBU;
Task tarefaOutraBU = new Task(
  WhatId = outraBU.Id,
  Subject = 'Tarefa da outra BU ' + TAG,
  OwnerId = UserInfo.getUserId(),
  Status = 'Open',
  ActivityDate = hoje.addDays(3)
);
insert tarefaOutraBU;

update new Opportunity(
  Id = outraBU.Id,
  StageName = 'Perdido',
  STE_Motivo_Perda__c = 'Desistiu'
);

Opportunity depois = [
  SELECT StageName, RecordTypeId, SOL_Qtd_Perdas__c, SOL_Produto_Negocio__c, SOL_Data_Encerramento__c
  FROM Opportunity
  WHERE Id = :outraBU.Id
];
Task tDepois = [
  SELECT Status, SOL_Motivo_Cancelamento__c, SOL_Cancelada_Por_Perda__c, SOL_Encerrado_Pela_Oportunidade__c
  FROM Task
  WHERE Id = :tarefaOutraBU.Id
];
Integer eventosOutraBU = [
  SELECT COUNT() FROM SOL_Evento_Jornada__c WHERE SOL_Oportunidade__c = :outraBU.Id
];

ok('[1] a Oportunidade de outra BU foi perdida NORMALMENTE', depois.StageName == 'Perdido', depois.StageName);
ok('[1] o vetor está armado: produto SOL preenchido', depois.SOL_Produto_Negocio__c == RT_PRODUTO,
  String.valueOf(depois.SOL_Produto_Negocio__c));
ok('[1] Record Type continua o da outra BU', depois.RecordTypeId == rtOutraBU, String.valueOf(depois.RecordTypeId));
ok('[1] NÃO incrementou SOL_Qtd_Perdas__c', depois.SOL_Qtd_Perdas__c == null,
  'contador=' + depois.SOL_Qtd_Perdas__c);
ok('[1] NÃO criou ocorrência da jornada SOL', eventosOutraBU == 0, 'eventos=' + eventosOutraBU);
ok('[1] NÃO tocou na tarefa da outra BU',
  tDepois.Status == 'Open' && tDepois.SOL_Cancelada_Por_Perda__c != true
    && tDepois.SOL_Motivo_Cancelamento__c == null && tDepois.SOL_Encerrado_Pela_Oportunidade__c != true,
  'status=' + tDepois.Status + ' porPerda=' + tDepois.SOL_Cancelada_Por_Perda__c
    + ' motivo=' + tDepois.SOL_Motivo_Cancelamento__c
    + ' encerradoPelaOpp=' + tDepois.SOL_Encerrado_Pela_Oportunidade__c);

// ---------------------------------------------- [2] CONTRAPROVA POSITIVA
Opportunity daBU = new Opportunity(
  Name = 'Op SOL ' + TAG,
  AccountId = a.Id,
  RecordTypeId = rtSOL,
  CloseDate = hoje.addDays(30),
  StageName = 'Diagnóstico',
  SOL_Produto_Negocio__c = RT_PRODUTO,
  SOL_ECAC_Consulta_Realizada__c = true,
  SOL_ECAC_Data_Consulta__c = hoje,
  SOL_ECAC_Resultado__c = 'Valor a recuperar',
  SOL_Valor_Recuperavel__c = 1000,
  SOL_Apresentacao_Realizada__c = true,
  SOL_Data_Apresentacao__c = hoje,
  SOL_Resultado_Apresentacao__c = 'Sucesso',
  SOL_Percentual_Comissao__c = 20,
  SOL_Valor_Servico__c = 5000
);
insert daBU;
update new Opportunity(Id = daBU.Id, StageName = 'Negociação');
update new Opportunity(Id = daBU.Id, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');

Opportunity daBUDepois = [SELECT SOL_Qtd_Perdas__c FROM Opportunity WHERE Id = :daBU.Id];
Integer eventosDaBU = [SELECT COUNT() FROM SOL_Evento_Jornada__c WHERE SOL_Oportunidade__c = :daBU.Id];
ok('[2] CONTRAPROVA: a mesma perda no Record Type SOL incrementa', daBUDepois.SOL_Qtd_Perdas__c == 1,
  'contador=' + daBUDepois.SOL_Qtd_Perdas__c);
ok('[2] CONTRAPROVA: e gera a ocorrência', eventosDaBU == 1, 'eventos=' + eventosDaBU);

// ---------------------------------------------------------------- limpeza
System.debug(LoggingLevel.ERROR, '--- limpeza: o cenário negativo não fica no relatório ---');
delete [SELECT Id FROM SOL_Evento_Jornada__c WHERE SOL_Oportunidade__c IN (:outraBU.Id, :daBU.Id)];
delete [SELECT Id FROM Task WHERE WhatId IN (:outraBU.Id, :daBU.Id)];
delete [SELECT Id FROM Opportunity WHERE Id IN (:outraBU.Id, :daBU.Id)];
delete a;

System.debug(LoggingLevel.ERROR, '=== RESULTADO: ' + (falhas == 0 ? 'TODAS AS VERIFICAÇÕES PASSARAM' : falhas + ' VERIFICAÇÃO(ÕES) FALHARAM') + ' ===');

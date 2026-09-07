/**
 * CLICKUP-9438 — E2E REAL do livro-razão de reatribuições e perdas da jornada
 * Arnone Soluções (SOL_Evento_Jornada__c).
 *
 * Roda contra a org com os Flows ATIVOS e a fila REAL (Fila_Leads_SOL): cada
 * ocorrência abaixo nasce pela via normal — inserir Lead, concluir tarefa,
 * mudar a etapa da Oportunidade — e o evento é consequência da automação, não
 * de chamada direta ao serviço de registro.
 *
 * COBERTURA
 *   [1] Reatribuição por falta de contato, DUAS vezes no mesmo Lead:
 *       ocorrências distintas, sequência 1 e 2, vendedores encadeados.
 *   [2] Reatribuição por estouro do prazo total (ART 360).
 *   [3] Lead perdido por opt-out (Recuperação Tributária).
 *   [4] Oportunidade perdida saindo de Negociação e de Fechamento — a ETAPA
 *       ANTERIOR real, nunca "Perdido".
 *   [5] Isolamento de outras BUs: nada é registrado fora da Arnone Soluções.
 *   [6] Idempotência: reprocessar não duplica.
 *   [7] Proprietário do evento = vendedor do instante da ocorrência.
 *   [8] Objeto de backend: sem aba e sem Create/Edit/Delete em Permission Set.
 *   [9] Resumo por motivo, com percentual — os números que o relatório precisa
 *       reproduzir. A CONFERÊNCIA contra o relatório executado de verdade fica
 *       em clickup-9438-e2e-conferencia-relatorio.apex, que roda depois, em
 *       outra transação: o motor de relatórios só enxerga dado commitado.
 *
 * Execução:
 *   sf apex run --file scripts/apex/clickup-9438-e2e-relatorio-reatribuicoes-perdas.apex --target-org <alias>
 *
 * Cria dados próprios com o prefixo E2E_9438. NÃO faz backfill e NÃO altera
 * agendamento nenhum.
 */
String TAG = 'E2E_9438-' + Datetime.now().getTime();
String RT_PRODUTO = 'Recuperação Tributária';
String ART = 'ART 360';
Id rtLead = Lead.SObjectType.getDescribe()
  .getRecordTypeInfosByDeveloperName()
  .get('SOL')
  .getRecordTypeId();
Id rtOpp = Opportunity.SObjectType.getDescribe()
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

System.debug(LoggingLevel.ERROR, '=== CLICKUP-9438 · E2E EVENTOS DA JORNADA (' + TAG + ') ===');

// ------------------------------------------------------------------ fixtures
Id novoLead(String produto, String sufixo) {
  Lead l = new Lead(
    RecordTypeId = rtLead,
    LastName = 'Evt ' + sufixo,
    Company = 'C ' + sufixo,
    Status = 'Captação - Contato',
    CNPJ__c = '11222333000181',
    SOL_Produto_Interesse__c = produto
  );
  Database.DMLOptions o = new Database.DMLOptions();
  o.duplicateRuleHeader.allowSave = true;
  Database.insert(l, o);
  // A "1ª Ligação" da distribuição inicial sai de cena: as tentativas abaixo
  // é que precisam ser contadas.
  delete [SELECT Id FROM Task WHERE WhoId = :l.Id AND Subject = '1ª Ligação'];
  return l.Id;
}

Id novaOpp(String produto, String etapa, String sufixo, Datetime inicio, Datetime prazo) {
  Account a = new Account(Name = 'Conta ' + sufixo);
  insert a;
  Opportunity o = new Opportunity(
    Name = 'Op ' + sufixo,
    AccountId = a.Id,
    RecordTypeId = rtOpp,
    CloseDate = hoje.addDays(60),
    StageName = 'Diagnóstico',
    SOL_Produto_Negocio__c = produto,
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
  if (inicio != null) {
    o.SOL_Data_Inicio_Ciclo_Comercial__c = inicio;
  }
  if (prazo != null) {
    o.SOL_Prazo_Total_Comercial__c = prazo;
  }
  insert o;
  if (etapa != 'Diagnóstico') {
    update new Opportunity(Id = o.Id, StageName = 'Negociação');
    if (etapa != 'Negociação') {
      update new Opportunity(Id = o.Id, StageName = etapa);
    }
  }
  return o.Id;
}

void tentativas(Id leadId, Integer qtd, String sufixo) {
  List<Task> ts = new List<Task>();
  for (Integer i = 0; i < qtd; i++) {
    ts.add(
      new Task(
        WhoId = leadId,
        Subject = 'Tentativa ' + sufixo + '-' + i,
        Status = 'Completed',
        ActivityDate = hoje,
        SOL_Tipo_Tarefa__c = 'Contato',
        SOL_Canal_Contato__c = 'Ligação',
        SOL_Resultado_Contato__c = 'Não atendeu'
      )
    );
  }
  insert ts;
}

List<SOL_Evento_Jornada__c> eventosDoLead(Id leadId) {
  return [
    SELECT
      Id, OwnerId, SOL_Motivo__c, SOL_Tipo_Evento__c, SOL_Origem__c,
      SOL_Vendedor__c, SOL_Novo_Vendedor__c, SOL_Produto__c,
      SOL_Record_Type_Origem__c, SOL_Sequencia__c, SOL_Etapa_Anterior__c,
      SOL_Chave_Idempotencia__c, SOL_Data_Ocorrencia__c
    FROM SOL_Evento_Jornada__c
    WHERE SOL_Lead__c = :leadId
    ORDER BY SOL_Sequencia__c ASC
  ];
}

List<SOL_Evento_Jornada__c> eventosDaOpp(Id oppId) {
  return [
    SELECT
      Id, OwnerId, SOL_Motivo__c, SOL_Tipo_Evento__c, SOL_Origem__c,
      SOL_Vendedor__c, SOL_Novo_Vendedor__c, SOL_Produto__c,
      SOL_Record_Type_Origem__c, SOL_Sequencia__c, SOL_Etapa_Anterior__c,
      SOL_Chave_Idempotencia__c, SOL_Data_Ocorrencia__c
    FROM SOL_Evento_Jornada__c
    WHERE SOL_Oportunidade__c = :oppId
    ORDER BY SOL_Sequencia__c ASC
  ];
}

Datetime inicioDoE2E = Datetime.now();
Set<Id> registrosDoE2E = new Set<Id>();

// ============ [1] REATRIBUIÇÃO POR FALTA DE CONTATO — DUAS VEZES NO MESMO LEAD
Id leadFC = novoLead(RT_PRODUTO, TAG + '-fc');
registrosDoE2E.add(leadFC);
Id vendedor1 = [SELECT OwnerId FROM Lead WHERE Id = :leadFC].OwnerId;
tentativas(leadFC, 3, 'a');
Id vendedor2 = [SELECT OwnerId FROM Lead WHERE Id = :leadFC].OwnerId;
// Ao reatribuir, o serviço reinicia o ciclo em "última conclusão + 1s" para as
// tarefas que dispararam a troca não voltarem a contar. Numa transação rápida a
// RODADA SEGUINTE cai dentro desse mesmo segundo e a 2ª reatribuição não
// acontece — o E2E ficaria dependente da velocidade da máquina. Antecipar o
// início do ciclo torna a segunda rodada determinística sem mascarar nada: o
// que se verifica aqui é a OCORRÊNCIA gravada, não a régua de contagem.
update new Lead(Id = leadFC, SOL_Data_Inicio_Ciclo_Contato__c = Datetime.now().addMinutes(-1));
tentativas(leadFC, 3, 'b');
Id vendedor3 = [SELECT OwnerId FROM Lead WHERE Id = :leadFC].OwnerId;

List<SOL_Evento_Jornada__c> evFC = eventosDoLead(leadFC);
System.debug(LoggingLevel.ERROR, '[1] REATRIBUIÇÃO POR FALTA DE CONTATO');
ok('[1] duas ocorrências para duas reatribuições', evFC.size() == 2, 'ocorrências=' + evFC.size());
if (evFC.size() == 2) {
  ok('[1] motivo correto', evFC[0].SOL_Motivo__c == 'Reatribuição por falta de contato', evFC[0].SOL_Motivo__c);
  ok('[1] sequência 1 e 2', evFC[0].SOL_Sequencia__c == 1 && evFC[1].SOL_Sequencia__c == 2,
    evFC[0].SOL_Sequencia__c + ' / ' + evFC[1].SOL_Sequencia__c);
  ok('[1] vendedor anterior da 1ª = dono original', evFC[0].SOL_Vendedor__c == vendedor1,
    'evento=' + evFC[0].SOL_Vendedor__c + ' esperado=' + vendedor1);
  ok('[1] novo vendedor da 1ª = dono após a 1ª troca', evFC[0].SOL_Novo_Vendedor__c == vendedor2,
    'evento=' + evFC[0].SOL_Novo_Vendedor__c + ' esperado=' + vendedor2);
  ok('[1] a 2ª ocorrência começa onde a 1ª terminou', evFC[1].SOL_Vendedor__c == vendedor2,
    'evento=' + evFC[1].SOL_Vendedor__c + ' esperado=' + vendedor2);
  ok('[1] novo vendedor da 2ª = dono atual', evFC[1].SOL_Novo_Vendedor__c == vendedor3,
    'evento=' + evFC[1].SOL_Novo_Vendedor__c + ' esperado=' + vendedor3);
  ok('[1] chaves distintas', evFC[0].SOL_Chave_Idempotencia__c != evFC[1].SOL_Chave_Idempotencia__c,
    evFC[0].SOL_Chave_Idempotencia__c + ' | ' + evFC[1].SOL_Chave_Idempotencia__c);
  ok('[1] produto congelado', evFC[0].SOL_Produto__c == RT_PRODUTO, String.valueOf(evFC[0].SOL_Produto__c));
  ok('[1] Record Type de origem', evFC[0].SOL_Record_Type_Origem__c == 'SOL', String.valueOf(evFC[0].SOL_Record_Type_Origem__c));
  ok('[1] PROPRIETÁRIO do evento = vendedor do instante', evFC[0].OwnerId == vendedor1,
    'owner=' + evFC[0].OwnerId + ' vendedor=' + vendedor1);
}

// ================================ [2] REATRIBUIÇÃO POR ESTOURO DO PRAZO TOTAL
Id oppPrazo = novaOpp(ART, 'Negociação', TAG + '-pz', Datetime.now().addDays(-60), Datetime.now().addDays(-1));
registrosDoE2E.add(oppPrazo);
Id donoPrazoAntes = [SELECT OwnerId FROM Opportunity WHERE Id = :oppPrazo].OwnerId;
SOLPrazoTotalService.ResultadoPrazoTotal rPz = SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppPrazo });
Id donoPrazoDepois = [SELECT OwnerId FROM Opportunity WHERE Id = :oppPrazo].OwnerId;
List<SOL_Evento_Jornada__c> evPz = eventosDaOpp(oppPrazo);
System.debug(LoggingLevel.ERROR, '[2] REATRIBUIÇÃO POR ESTOURO DO PRAZO TOTAL (reatribuidas=' + rPz.reatribuidas + ')');
ok('[2] uma ocorrência', evPz.size() == 1, 'ocorrências=' + evPz.size());
if (!evPz.isEmpty()) {
  ok('[2] motivo correto', evPz[0].SOL_Motivo__c == 'Reatribuição por estouro do prazo total', evPz[0].SOL_Motivo__c);
  ok('[2] origem Oportunidade', evPz[0].SOL_Origem__c == 'Oportunidade', evPz[0].SOL_Origem__c);
  ok('[2] vendedor anterior', evPz[0].SOL_Vendedor__c == donoPrazoAntes, String.valueOf(evPz[0].SOL_Vendedor__c));
  ok('[2] novo vendedor', evPz[0].SOL_Novo_Vendedor__c == donoPrazoDepois, String.valueOf(evPz[0].SOL_Novo_Vendedor__c));
  ok('[2] produto ART 360', evPz[0].SOL_Produto__c == ART, String.valueOf(evPz[0].SOL_Produto__c));
  ok('[2] sem etapa anterior (é reatribuição, não perda)', evPz[0].SOL_Etapa_Anterior__c == null,
    String.valueOf(evPz[0].SOL_Etapa_Anterior__c));
}

// ================================================ [3] LEAD PERDIDO POR OPT-OUT
Id leadOO = novoLead(RT_PRODUTO, TAG + '-oo');
registrosDoE2E.add(leadOO);
Id donoOO = [SELECT OwnerId FROM Lead WHERE Id = :leadOO].OwnerId;
// Caminho REAL: tarefa de contato concluída com resultado "Opt-out" dispara o
// Flow SOL_Opt_Out, que chama o serviço.
insert new Task(
  WhoId = leadOO,
  Subject = 'Contato ' + TAG,
  Status = 'Completed',
  ActivityDate = hoje,
  SOL_Tipo_Tarefa__c = 'Contato',
  SOL_Canal_Contato__c = 'Ligação',
  SOL_Resultado_Contato__c = 'Opt-out'
);
Lead lOO = [SELECT Status, SOL_Opt_Out__c, SOL_Motivo_Desqualificacao__c FROM Lead WHERE Id = :leadOO];
List<SOL_Evento_Jornada__c> evOO = eventosDoLead(leadOO);
System.debug(LoggingLevel.ERROR, '[3] LEAD PERDIDO POR OPT-OUT (optOut=' + lOO.SOL_Opt_Out__c + ')');
ok('[3] uma ocorrência', evOO.size() == 1, 'ocorrências=' + evOO.size());
if (!evOO.isEmpty()) {
  ok('[3] motivo correto', evOO[0].SOL_Motivo__c == 'Lead perdido por opt-out', evOO[0].SOL_Motivo__c);
  ok('[3] tipo Perda', evOO[0].SOL_Tipo_Evento__c == 'Perda', evOO[0].SOL_Tipo_Evento__c);
  ok('[3] vendedor responsável', evOO[0].SOL_Vendedor__c == donoOO, String.valueOf(evOO[0].SOL_Vendedor__c));
  ok('[3] sem novo vendedor', evOO[0].SOL_Novo_Vendedor__c == null, String.valueOf(evOO[0].SOL_Novo_Vendedor__c));
}

// ======================================= [4] OPORTUNIDADE PERDIDA — DUAS ETAPAS
Map<String, Id> perdaPorEtapa = new Map<String, Id>();
perdaPorEtapa.put('Negociação', novaOpp(RT_PRODUTO, 'Negociação', TAG + '-pn', null, null));
perdaPorEtapa.put('Fechamento', novaOpp(ART, 'Fechamento', TAG + '-pf', null, null));
System.debug(LoggingLevel.ERROR, '[4] OPORTUNIDADE PERDIDA');
for (String etapa : perdaPorEtapa.keySet()) {
  Id oid = perdaPorEtapa.get(etapa);
  registrosDoE2E.add(oid);
  Id dono = [SELECT OwnerId FROM Opportunity WHERE Id = :oid].OwnerId;
  update new Opportunity(Id = oid, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');
  List<SOL_Evento_Jornada__c> evP = eventosDaOpp(oid);
  ok('[4] uma ocorrência saindo de ' + etapa, evP.size() == 1, 'ocorrências=' + evP.size());
  if (!evP.isEmpty()) {
    ok('[4] motivo correto (' + etapa + ')', evP[0].SOL_Motivo__c == 'Oportunidade perdida', evP[0].SOL_Motivo__c);
    ok('[4] ETAPA ANTERIOR real (' + etapa + ')', evP[0].SOL_Etapa_Anterior__c == etapa,
      'gravado=' + evP[0].SOL_Etapa_Anterior__c + ' esperado=' + etapa);
    ok('[4] etapa anterior NUNCA é "Perdido" (' + etapa + ')', evP[0].SOL_Etapa_Anterior__c != 'Perdido',
      String.valueOf(evP[0].SOL_Etapa_Anterior__c));
    ok('[4] vendedor responsável (' + etapa + ')', evP[0].SOL_Vendedor__c == dono, String.valueOf(evP[0].SOL_Vendedor__c));
  }
}

// =================================================== [5] ISOLAMENTO DE OUTRAS BUs
Integer antesIsolamento = [SELECT COUNT() FROM SOL_Evento_Jornada__c];
Lead leadOutraBU = new Lead(LastName = 'ForaBU ' + TAG, Company = 'C', Status = 'Captação - Contato');
Database.DMLOptions dmo = new Database.DMLOptions();
dmo.duplicateRuleHeader.allowSave = true;
Database.insert(leadOutraBU, dmo);
insert new Task(
  WhoId = leadOutraBU.Id,
  Subject = 'Contato fora da BU ' + TAG,
  Status = 'Completed',
  ActivityDate = hoje,
  SOL_Tipo_Tarefa__c = 'Contato',
  SOL_Canal_Contato__c = 'Ligação',
  SOL_Resultado_Contato__c = 'Opt-out'
);
SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ leadOutraBU.Id });
Integer depoisIsolamento = [SELECT COUNT() FROM SOL_Evento_Jornada__c];
System.debug(LoggingLevel.ERROR, '[5] ISOLAMENTO DE OUTRAS BUs');
ok('[5] nada registrado fora da Arnone Soluções', antesIsolamento == depoisIsolamento,
  'antes=' + antesIsolamento + ' depois=' + depoisIsolamento);

// ========================================================== [6] IDEMPOTÊNCIA
Integer antesReprocesso = [SELECT COUNT() FROM SOL_Evento_Jornada__c];
SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ leadFC });
SOLDistribuicaoService.registrarOptOut(new List<Id>{ leadOO });
SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppPrazo });
SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
  new List<Id>{ perdaPorEtapa.get('Negociação') },
  new Map<Id, String>{ perdaPorEtapa.get('Negociação') => 'Negociação' }
);
Integer depoisReprocesso = [SELECT COUNT() FROM SOL_Evento_Jornada__c];
System.debug(LoggingLevel.ERROR, '[6] IDEMPOTÊNCIA');
ok('[6] reprocessar os quatro caminhos não duplica', antesReprocesso == depoisReprocesso,
  'antes=' + antesReprocesso + ' depois=' + depoisReprocesso);

// =========================== [7] OBJETO DE BACKEND: SEM ABA E SEM ESCRITA MANUAL
System.debug(LoggingLevel.ERROR, '[7] OBJETO DE BACKEND');
Integer abas = [SELECT COUNT() FROM TabDefinition WHERE SobjectName = 'SOL_Evento_Jornada__c'];
ok('[7] o objeto NÃO tem aba', abas == 0, 'abas=' + abas);
List<ObjectPermissions> perms = [
  SELECT Parent.Label, Parent.Name, Parent.IsOwnedByProfile, Parent.PermissionsViewAllData,
         Parent.PermissionsModifyAllData, PermissionsRead, PermissionsCreate,
         PermissionsEdit, PermissionsDelete, PermissionsViewAllRecords, PermissionsModifyAllRecords
  FROM ObjectPermissions
  WHERE SobjectType = 'SOL_Evento_Jornada__c'
];
Integer comEscrita = 0;
Integer comViewAll = 0;
Integer integracoesPreExistentes = 0;
for (ObjectPermissions p : perms) {
  System.debug(LoggingLevel.ERROR, '[7]   ' + p.Parent.Label + ' (perfil=' + p.Parent.IsOwnedByProfile + ')'
    + ' read=' + p.PermissionsRead + ' create=' + p.PermissionsCreate + ' edit=' + p.PermissionsEdit
    + ' delete=' + p.PermissionsDelete + ' viewAll=' + p.PermissionsViewAllRecords);
  // Perfis herdam permissões por "Modify All Data"; o card fala de Permission
  // Sets, que são o mecanismo de concessão deste repositório.
  if (p.Parent.IsOwnedByProfile) {
    continue;
  }
  // Permission Sets de INTEGRAÇÃO da plataforma (Slack, Data Cloud) carregam
  // "View All Data" no nível da ORG: eles enxergam qualquer objeto novo, e isso
  // não é concessão deste card nem pode ser revogado por ele. Ficam listados
  // como acesso pré-existente, não como falha.
  if (p.Parent.PermissionsViewAllData || p.Parent.PermissionsModifyAllData) {
    integracoesPreExistentes++;
    continue;
  }
  if (p.PermissionsCreate || p.PermissionsEdit || p.PermissionsDelete) {
    comEscrita++;
  }
  if (p.PermissionsViewAllRecords || p.PermissionsModifyAllRecords) {
    comViewAll++;
  }
}
ok('[7] nenhum Permission Set com Create/Edit/Delete', comEscrita == 0, 'permission sets com escrita=' + comEscrita);
ok('[7] nenhum Permission Set do card com View All/Modify All', comViewAll == 0,
  'com View All=' + comViewAll + ' | integrações com View All Data da org (pré-existentes)=' + integracoesPreExistentes);
for (ObjectPermissions p : [
  SELECT PermissionsRead, PermissionsCreate, PermissionsEdit, PermissionsDelete, PermissionsViewAllRecords
  FROM ObjectPermissions
  WHERE SobjectType = 'SOL_Evento_Jornada__c' AND Parent.Name = 'PS_SOL_Comercial'
]) {
  ok('[7] PS_SOL_Comercial: leitura mínima, sem escrita e sem View All',
    p.PermissionsRead && !p.PermissionsCreate && !p.PermissionsEdit && !p.PermissionsDelete && !p.PermissionsViewAllRecords,
    'read=' + p.PermissionsRead + ' create=' + p.PermissionsCreate + ' edit=' + p.PermissionsEdit
      + ' delete=' + p.PermissionsDelete + ' viewAll=' + p.PermissionsViewAllRecords);
}

// ================================= [8] RESUMO POR MOTIVO — INSUMO DO RELATÓRIO
System.debug(LoggingLevel.ERROR, '[8] RESUMO POR MOTIVO (confronto com o relatório em outra execução)');
Integer total = 0;
Map<String, Integer> porMotivo = new Map<String, Integer>();
for (AggregateResult ar : [
  SELECT SOL_Motivo__c motivo, COUNT(Id) qtd
  FROM SOL_Evento_Jornada__c
  WHERE SOL_Record_Type_Origem__c = 'SOL'
  GROUP BY SOL_Motivo__c
]) {
  Integer q = (Integer) ar.get('qtd');
  porMotivo.put((String) ar.get('motivo'), q);
  total += q;
}
Decimal somaPct = 0;
for (String m : porMotivo.keySet()) {
  Decimal pct = total == 0 ? 0 : (Decimal.valueOf(porMotivo.get(m)) / total * 100).setScale(2);
  somaPct += pct;
  System.debug(LoggingLevel.ERROR, '[8]   ' + m + ' = ' + porMotivo.get(m) + '  (' + pct + '%)');
}
System.debug(LoggingLevel.ERROR, '[8]   TOTAL = ' + total + '  (' + somaPct + '%)');
ok('[8] os quatro motivos estão representados', porMotivo.size() == 4, 'motivos=' + porMotivo.size());
ok('[8] percentuais somam 100% (salvo arredondamento)', Math.abs(somaPct - 100) <= 0.05, 'soma=' + somaPct);

Integer noPeriodo = [
  SELECT COUNT() FROM SOL_Evento_Jornada__c WHERE SOL_Data_Ocorrencia__c >= :inicioDoE2E
];
System.debug(LoggingLevel.ERROR, '[8]   ocorrências deste E2E (data da ocorrência >= início) = ' + noPeriodo);

// ============================================ [9] SEM BACKFILL — LIMITE EXPLÍCITO
Integer reatribHistoricas = [
  SELECT COUNT() FROM Lead WHERE SOL_Quantidade_Reatribuicoes__c > 0
];
System.debug(LoggingLevel.ERROR, '[9] SEM BACKFILL: ' + reatribHistoricas
  + ' Leads têm contador de reatribuição > 0 e NÃO viraram ocorrência retroativa.'
  + ' A série começa na data de implantação — o histórico anterior não é correlacionável com segurança.');

System.debug(LoggingLevel.ERROR, '=== RESULTADO: ' + (falhas == 0 ? 'TODAS AS VERIFICAÇÕES PASSARAM' : falhas + ' VERIFICAÇÃO(ÕES) FALHARAM') + ' ===');
System.debug(LoggingLevel.ERROR, '=== registros do E2E: ' + registrosDoE2E + ' ===');

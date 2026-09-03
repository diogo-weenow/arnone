/**
 * CLICKUP-9421 — Card 10 — Testes da criação automática da tarefa de
 * acompanhamento do cálculo jurídico.
 *
 * O Flow after-save de Opportunity SOL_Tarefa_Acompanhamento_Calculo está ATIVO:
 * quando uma Oportunidade da Arnone Soluções (Record Type SOL, produto
 * "Recuperação Tributária", etapa "Diagnóstico", aberta) tem
 * SOL_Data_Solicitacao_Calculo__c preenchida (ISCHANGED), o Apex
 * SOLAcompanhamentoCalculoService cria UMA Task "Acompanhar recebimento do
 * cálculo jurídico" com vencimento 7 dias úteis. A maioria dos testes preenche
 * a data com um update direto na Opp — o MESMO gatilho de produção
 * (ISCHANGED do campo), sem depender da conversão de Lead nem das validações do
 * Card 09. Um teste exercita o caminho completo pela ação do Card 09
 * (SOLSolicitarCalculoService.registrar).
 *
 * Concorrência: protegida pelo SELECT ... FOR UPDATE em
 * criarTarefaAcompanhamento. Duas transações paralelas NÃO são simuláveis em
 * teste Apex — os testes cobrem a idempotência SEQUENCIAL.
 *
 * FERIADO: a implementação delega a BusinessHours.nextStartDate, que respeita os
 * feriados do calendário. Um Holiday inserido em teste não se associa a um
 * Business Hours não-default, então não há teste automatizado direto de feriado
 * (cobertura = configurar o calendário em Setup).
 */
@IsTest
private class SOLAcompanhamentoCalculoTest {
  private static final String PRODUTO = 'Recuperação Tributária';
  private static final String TIPO = 'Acompanhamento do cálculo jurídico';
  private static final String SUBJECT = 'Acompanhar recebimento do cálculo jurídico';
  private static final String TZ_SP = 'America/Sao_Paulo';
  private static Integer seq = 0;

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ---------------------------------------------------------------- helpers

  private static String rnd() {
    seq++;
    return seq + 'x' + String.valueOf(Math.abs(Crypto.getRandomInteger()));
  }

  private static Id rtOppSOL() {
    return Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Id rtLeadSOL() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Id bhId() {
    Id v = SOLBusinessHoursHelper.businessHoursId();
    System.assertNotEquals(null, v, 'Business Hours comercial é pré-requisito.');
    return v;
  }

  private static Date vencimentoEsperado(Date solicitacao) {
    return SOLBusinessHoursHelper.dataEm(
      SOLBusinessHoursHelper.prazoEmDiasUteis(bhId(), solicitacao, 7),
      TZ_SP
    );
  }

  /**
   * Cria uma Opp. prodOpp = produto; etapaOpp = "Diagnóstico"/"Negociação"/"Perdido";
   * oppSOL = Record Type SOL (false => outra BU); owner = proprietário (ou null).
   * NÃO preenche SOL_Data_Solicitacao_Calculo__c (isso dispara o Flow).
   */
  private static Id novaOpp(String prodOpp, String etapaOpp, Boolean oppSOL, Id owner) {
    Account a = new Account(Name = 'Conta ' + rnd());
    insert a;
    Opportunity o = new Opportunity(
      Name = 'Op ' + rnd(),
      AccountId = a.Id,
      CloseDate = Date.today().addDays(60),
      StageName = 'Diagnóstico',
      SOL_Produto_Negocio__c = prodOpp
    );
    if (oppSOL) {
      o.RecordTypeId = rtOppSOL();
    }
    if (etapaOpp == 'Negociação') {
      o.SOL_ECAC_Consulta_Realizada__c = true;
      o.SOL_ECAC_Data_Consulta__c = Date.today();
      o.SOL_ECAC_Resultado__c = 'Valor a recuperar';
      o.SOL_Valor_Recuperavel__c = 1000;
      o.StageName = 'Negociação';
    } else if (etapaOpp == 'Perdido') {
      o.SOL_Motivo_Perda__c = 'Sem interesse';
      o.StageName = 'Perdido';
    } else {
      o.StageName = etapaOpp;
    }
    if (owner != null) {
      o.OwnerId = owner;
    }
    insert o;
    return o.Id;
  }

  private static Id oppDiagnostico() {
    return novaOpp(PRODUTO, 'Diagnóstico', true, null);
  }

  /** Preenche a data da solicitação — dispara o Flow do CLICKUP-9421. */
  private static void registrarSolicitacao(Id oppId, Date data) {
    update new Opportunity(Id = oppId, SOL_Data_Solicitacao_Calculo__c = data);
  }

  private static List<Task> tarefas(Id oppId) {
    return [
      SELECT
        Id,
        Subject,
        Status,
        OwnerId,
        WhatId,
        ActivityDate,
        SOL_Tipo_Tarefa__c,
        SOL_Data_Solicitacao_Calculo_Ref__c,
        SOL_Data_Recebimento_Calculo__c
      FROM Task
      WHERE WhatId = :oppId AND SOL_Tipo_Tarefa__c = :TIPO
    ];
  }

  private static Task tarefaAcompanhamento(Id oppId, Id owner, Date ref, String status) {
    Task t = new Task(
      Subject = 'acompanhamento pré-existente',
      WhatId = oppId,
      OwnerId = owner,
      Status = status,
      ActivityDate = Date.today().addDays(3),
      SOL_Tipo_Tarefa__c = TIPO,
      SOL_Data_Solicitacao_Calculo_Ref__c = ref
    );
    insert t;
    return t;
  }

  private static Opportunity recarregar(Id oppId) {
    return [
      SELECT Id, StageName, SOL_Data_Solicitacao_Calculo__c
      FROM Opportunity
      WHERE Id = :oppId
    ];
  }

  // ============================================================ POSITIVO

  @IsTest
  static void criaTarefa_camposEPrazo() {
    Id opp = oppDiagnostico();
    Id owner = [SELECT OwnerId FROM Opportunity WHERE Id = :opp].OwnerId;
    Date hoje = Date.today();

    Test.startTest();
    registrarSolicitacao(opp, hoje);
    Test.stopTest();

    List<Task> ts = tarefas(opp);
    System.assertEquals(1, ts.size(), 'Uma tarefa de acompanhamento.');
    System.assertEquals(SUBJECT, ts[0].Subject);
    System.assertEquals('Open', ts[0].Status);
    System.assertEquals(opp, ts[0].WhatId, 'WhatId = Oportunidade.');
    System.assertEquals(owner, ts[0].OwnerId, 'Responsável = proprietário atual da Oportunidade.');
    System.assertEquals(TIPO, ts[0].SOL_Tipo_Tarefa__c);
    System.assertEquals(hoje, ts[0].SOL_Data_Solicitacao_Calculo_Ref__c, 'Referência = data da solicitação.');
    System.assertEquals(vencimentoEsperado(hoje), ts[0].ActivityDate, '7 dias úteis após a solicitação.');
    // Não avança a Oportunidade nem cria reunião final.
    System.assertEquals('Diagnóstico', recarregar(opp).StageName);
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhatId = :opp AND SOL_Tipo_Tarefa__c = 'Reunião comercial']
    );
  }

  @IsTest
  static void criaTarefa_pelaAcaoDoCard09() {
    // Caminho completo: SOLSolicitarCalculoService.registrar grava a data e o
    // Flow after-save dispara a criação da tarefa, na mesma transação.
    Account a = new Account(Name = 'Conta ' + rnd());
    insert a;
    Contact c = new Contact(LastName = 'Contato ' + rnd(), AccountId = a.Id);
    insert c;
    Opportunity o = new Opportunity(
      Name = 'Op ' + rnd(),
      AccountId = a.Id,
      RecordTypeId = rtOppSOL(),
      CloseDate = Date.today().addDays(60),
      StageName = 'Diagnóstico',
      SOL_Produto_Negocio__c = PRODUTO
    );
    insert o;
    Lead l = new Lead(LastName = 'Lead ' + rnd(), Company = 'C');
    insert l;
    update new Lead(
      Id = l.Id,
      SOL_Data_Reuniao_Realizada__c = Datetime.now().addDays(-1),
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = Date.today().addDays(-1)
    );
    ContentVersion cv = new ContentVersion(
      Title = 'doc' + rnd(),
      PathOnClient = 'p.txt',
      VersionData = Blob.valueOf('x')
    );
    insert cv;
    insert new ContentDocumentLink(
      ContentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id]
        .ContentDocumentId,
      LinkedEntityId = l.Id,
      ShareType = 'V'
    );
    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(l.Id);
    lc.setAccountId(a.Id);
    lc.setContactId(c.Id);
    lc.setOpportunityId(o.Id);
    lc.setConvertedStatus(
      [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1].MasterLabel
    );
    Database.convertLead(lc);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = SOLSolicitarCalculoService.registrar(
        new List<SOLSolicitarCalculoService.Pedido>{
          new SOLSolicitarCalculoService.Pedido(o.Id, Date.today())
        }
      )[0];
    Test.stopTest();

    System.assert(r.sucesso, r.mensagem);
    List<Task> ts = tarefas(o.Id);
    System.assertEquals(1, ts.size(), 'A ação do Card 09 dispara a tarefa de acompanhamento.');
    System.assertEquals(Date.today(), ts[0].SOL_Data_Solicitacao_Calculo_Ref__c);
  }

  // ============================================================ NÃO APLICA

  @IsTest
  static void art360NaoCria() {
    Id opp = novaOpp('ART 360', 'Diagnóstico', true, null);

    Test.startTest();
    registrarSolicitacao(opp, Date.today());
    Test.stopTest();

    System.assertEquals(0, tarefas(opp).size(), 'ART 360 fica fora do cálculo jurídico.');
  }

  @IsTest
  static void outraBUNaoCria() {
    Id opp = novaOpp(PRODUTO, 'Diagnóstico', false, null);

    Test.startTest();
    registrarSolicitacao(opp, Date.today());
    // chamada direta ao serviço também ignora.
    SOLAcompanhamentoCalculoService.ResultadoAcompanhamento r = SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(
      new List<Id>{ opp }
    );
    Test.stopTest();

    System.assertEquals(0, tarefas(opp).size());
    System.assert(r.ignorados >= 1);
  }

  @IsTest
  static void etapaDiferenteNaoCria() {
    Id opp = novaOpp(PRODUTO, 'Negociação', true, null);

    Test.startTest();
    registrarSolicitacao(opp, Date.today());
    Test.stopTest();

    System.assertEquals(0, tarefas(opp).size(), 'Fora de Diagnóstico não cria.');
  }

  @IsTest
  static void oportunidadeFechadaNaoCria() {
    Id opp = novaOpp(PRODUTO, 'Perdido', true, null);

    Test.startTest();
    SOLAcompanhamentoCalculoService.ResultadoAcompanhamento r = SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(
      new List<Id>{ opp }
    );
    Test.stopTest();

    System.assertEquals(0, r.tarefasCriadas);
    System.assert(r.ignorados >= 1);
  }

  @IsTest
  static void dataAusenteNaoCria() {
    Id opp = oppDiagnostico();

    Test.startTest();
    // Sem preencher SOL_Data_Solicitacao_Calculo__c: chamada direta ao serviço.
    SOLAcompanhamentoCalculoService.ResultadoAcompanhamento r = SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(
      new List<Id>{ opp }
    );
    // Uma atualização não relacionada também não dispara.
    update new Opportunity(Id = opp, Description = 'edição qualquer');
    Test.stopTest();

    System.assertEquals(0, r.tarefasCriadas);
    System.assertEquals(0, tarefas(opp).size());
  }

  @IsTest
  static void atualizacaoNaoRelacionadaNaoCriaOutra() {
    Id opp = oppDiagnostico();
    registrarSolicitacao(opp, Date.today());
    System.assertEquals(1, tarefas(opp).size());

    Test.startTest();
    update new Opportunity(Id = opp, Description = 'nota', NextStep = 'x');
    Test.stopTest();

    System.assertEquals(1, tarefas(opp).size(), 'Atualização não relacionada não cria outra.');
  }

  // ============================================================ IDEMPOTÊNCIA

  @IsTest
  static void reprocessamentoNaoDuplica() {
    Id opp = oppDiagnostico();
    Date hoje = Date.today();

    Test.startTest();
    registrarSolicitacao(opp, hoje);
    SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(new List<Id>{ opp });
    SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(new List<Id>{ opp });
    Test.stopTest();

    System.assertEquals(1, tarefas(opp).size(), 'Reprocessamento da mesma solicitação não duplica.');
  }

  @IsTest
  static void tarefaAnteriorAbertaNaoDuplica() {
    Id opp = oppDiagnostico();
    Id owner = [SELECT OwnerId FROM Opportunity WHERE Id = :opp].OwnerId;
    Date hoje = Date.today();
    tarefaAcompanhamento(opp, owner, hoje, 'Open');

    Test.startTest();
    registrarSolicitacao(opp, hoje);
    Test.stopTest();

    System.assertEquals(1, tarefas(opp).size(), 'Tarefa aberta da mesma solicitação: não recria.');
  }

  @IsTest
  static void tarefaAnteriorEncerradaNaoDuplica() {
    Id opp = oppDiagnostico();
    Id owner = [SELECT OwnerId FROM Opportunity WHERE Id = :opp].OwnerId;
    Date hoje = Date.today();
    Task fechada = tarefaAcompanhamento(opp, owner, hoje, 'Open');
    update new Task(Id = fechada.Id, Status = 'Completed', SOL_Data_Recebimento_Calculo__c = hoje);

    Test.startTest();
    registrarSolicitacao(opp, hoje);
    Test.stopTest();

    List<Task> ts = tarefas(opp);
    System.assertEquals(1, ts.size(), 'Tarefa encerrada da mesma solicitação conta — não recria.');
    System.assertEquals('Completed', ts[0].Status);
  }

  // ============================================================ BULK / CONCORRÊNCIA

  @IsTest
  static void processamentoBulk() {
    List<Opportunity> opps = new List<Opportunity>();
    for (Integer i = 0; i < 12; i++) {
      Account a = new Account(Name = 'C ' + rnd());
      insert a;
      opps.add(
        new Opportunity(
          Name = 'O ' + rnd(),
          AccountId = a.Id,
          RecordTypeId = rtOppSOL(),
          CloseDate = Date.today().addDays(60),
          StageName = 'Diagnóstico',
          SOL_Produto_Negocio__c = PRODUTO
        )
      );
    }
    insert opps;

    List<Opportunity> comData = new List<Opportunity>();
    for (Opportunity o : opps) {
      comData.add(new Opportunity(Id = o.Id, SOL_Data_Solicitacao_Calculo__c = Date.today()));
    }

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    update comData;
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    System.assertEquals(
      12,
      [SELECT COUNT() FROM Task WHERE WhatId IN :opps AND SOL_Tipo_Tarefa__c = :TIPO]
    );
    System.assert(soql < 15, 'SOQL não escala por Opp: ' + soql);
    System.assert(dml < 6, 'DML não escala por Opp: ' + dml);
  }

  @IsTest
  static void duasChamadasNaMesmaTransacaoCriamUmaSo() {
    // Idempotência SEQUENCIAL — NÃO é teste de concorrência. A proteção é o
    // SELECT ... FOR UPDATE em criarTarefaAcompanhamento.
    Id opp = oppDiagnostico();
    registrarSolicitacao(opp, Date.today());

    Test.startTest();
    SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(new List<Id>{ opp });
    SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(new List<Id>{ opp });
    Test.stopTest();

    System.assertEquals(1, tarefas(opp).size());
  }

  // ============================================================ ATOMICIDADE

  @IsTest
  static void calendarioAusenteAbortaComRollbackDaData() {
    Id opp = oppDiagnostico();

    Test.startTest();
    SOLBusinessHoursHelper.overrideBusinessHours(null);
    Boolean lancou = false;
    try {
      registrarSolicitacao(opp, Date.today());
    } catch (Exception e) {
      lancou = true;
      System.assert(
        e.getMessage().contains('calendário') || e.getMessage().contains('Arnone Soluções'),
        'Mensagem controlada de calendário ausente: ' + e.getMessage()
      );
    }
    Test.stopTest();

    System.assert(lancou, 'Calendário ausente aborta a transação.');
    System.assertEquals(0, tarefas(opp).size());
    System.assertEquals(
      null,
      recarregar(opp).SOL_Data_Solicitacao_Calculo__c,
      'A data da solicitação (Card 09) foi revertida — atômico.'
    );
  }

  @IsTest
  static void falhaNaCriacaoAbortaAtomicamente() {
    Id opp = oppDiagnostico();
    registrarSolicitacao(opp, Date.today());
    delete tarefas(opp);

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(new List<Id>{ opp });
    } catch (SOLAcompanhamentoCalculoService.AcompanhamentoCalculoException e) {
      lancou = true;
      System.assertEquals(SOLAcompanhamentoCalculoService.MSG_FALHA, e.getMessage());
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'Falha relança AcompanhamentoCalculoException.');
    System.assertEquals(0, tarefas(opp).size());
  }

  @IsTest
  static void invocableRelancaAFalha() {
    Id opp = oppDiagnostico();
    registrarSolicitacao(opp, Date.today());
    delete tarefas(opp);

    SOLAcompanhamentoCalculoInvocable.Entrada e = new SOLAcompanhamentoCalculoInvocable.Entrada();
    e.opportunityId = opp;

    Test.startTest();
    SOLBusinessHoursHelper.overrideBusinessHours(null);
    Boolean lancou = false;
    try {
      SOLAcompanhamentoCalculoInvocable.criar(
        new List<SOLAcompanhamentoCalculoInvocable.Entrada>{ e }
      );
    } catch (SOLAcompanhamentoCalculoService.AcompanhamentoCalculoException ex) {
      lancou = true;
    }
    Test.stopTest();

    System.assert(lancou, 'O Invocable relança a falha para o Flow abortar a transação.');
  }

  @IsTest
  static void invocableEServicoIgnoramEntradasInvalidas() {
    Test.startTest();
    SOLAcompanhamentoCalculoInvocable.criar(null);
    SOLAcompanhamentoCalculoInvocable.criar(new List<SOLAcompanhamentoCalculoInvocable.Entrada>());
    SOLAcompanhamentoCalculoInvocable.Entrada semId = new SOLAcompanhamentoCalculoInvocable.Entrada();
    SOLAcompanhamentoCalculoInvocable.criar(
      new List<SOLAcompanhamentoCalculoInvocable.Entrada>{ semId, null }
    );
    SOLAcompanhamentoCalculoService.ResultadoAcompanhamento r1 = SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(
      null
    );
    SOLAcompanhamentoCalculoService.ResultadoAcompanhamento r2 = SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(
      new List<Id>()
    );
    Test.stopTest();

    System.assertEquals(0, r1.tarefasCriadas);
    System.assertEquals(0, r2.tarefasCriadas);
    System.assertEquals(0, [SELECT COUNT() FROM Task WHERE SOL_Tipo_Tarefa__c = :TIPO]);
  }

  // ============================================================ CONCLUSÃO DA TAREFA (VRs)

  private static Task criarTarefaParaConcluir(Date vencimento) {
    // Referência bem no passado — os testes de conclusão focam nas VRs de
    // presença e de data futura, não na regra cronológica.
    return criarTarefaParaConcluir(vencimento, Date.today().addDays(-60));
  }

  private static Task criarTarefaParaConcluir(Date vencimento, Date refSolicitacao) {
    Id opp = oppDiagnostico();
    Task t = new Task(
      Subject = SUBJECT,
      WhatId = opp,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = vencimento,
      SOL_Tipo_Tarefa__c = TIPO,
      SOL_Data_Solicitacao_Calculo_Ref__c = refSolicitacao
    );
    insert t;
    return t;
  }

  @IsTest
  static void conclusaoSemDataBloqueada() {
    Task t = criarTarefaParaConcluir(Date.today().addDays(7));

    Test.startTest();
    Boolean bloqueou = false;
    try {
      update new Task(Id = t.Id, Status = 'Completed');
    } catch (DmlException e) {
      bloqueou = true;
      System.assert(e.getDmlMessage(0).containsIgnoreCase('data de recebimento'), e.getDmlMessage(0));
    }
    Test.stopTest();

    System.assert(bloqueou, 'Concluir sem SOL_Data_Recebimento_Calculo__c é bloqueado.');
  }

  @IsTest
  static void conclusaoComDataFuturaBloqueada() {
    Task t = criarTarefaParaConcluir(Date.today().addDays(7));

    Test.startTest();
    Boolean bloqueou = false;
    try {
      update new Task(
        Id = t.Id,
        SOL_Data_Recebimento_Calculo__c = Date.today().addDays(1),
        Status = 'Completed'
      );
    } catch (DmlException e) {
      bloqueou = true;
      System.assert(e.getDmlMessage(0).containsIgnoreCase('não pode ser futura'), e.getDmlMessage(0));
    }
    Test.stopTest();

    System.assert(bloqueou, 'Data de recebimento futura é rejeitada.');
  }

  @IsTest
  static void conclusaoComDataValidaPermitida_mesmoAposVencimento() {
    // Vencimento no passado (tarefa vencida) — a data válida ainda permite concluir.
    Task t = criarTarefaParaConcluir(Date.today().addDays(-30));

    Test.startTest();
    update new Task(
      Id = t.Id,
      SOL_Data_Recebimento_Calculo__c = Date.today().addDays(-2),
      Status = 'Completed'
    );
    Test.stopTest();

    Task depois = [SELECT Status, SOL_Data_Recebimento_Calculo__c FROM Task WHERE Id = :t.Id];
    System.assertEquals('Completed', depois.Status);
    System.assertEquals(Date.today().addDays(-2), depois.SOL_Data_Recebimento_Calculo__c);
  }

  // ================================================ RECEBIMENTO x SOLICITAÇÃO (VR cronológica)

  @IsTest
  static void recebimentoAnteriorASolicitacaoBloqueado() {
    // Solicitação hoje; recebimento ontem => antes da solicitação.
    Task t = criarTarefaParaConcluir(Date.today().addDays(7), Date.today());

    Test.startTest();
    Boolean bloqueou = false;
    try {
      update new Task(
        Id = t.Id,
        SOL_Data_Recebimento_Calculo__c = Date.today().addDays(-1),
        Status = 'Completed'
      );
    } catch (DmlException e) {
      bloqueou = true;
      System.assert(
        e.getDmlMessage(0).containsIgnoreCase('anterior à data da solicitação'),
        e.getDmlMessage(0)
      );
    }
    Test.stopTest();

    System.assert(bloqueou, 'Recebimento anterior à solicitação é bloqueado.');
    System.assertEquals('Open', [SELECT Status FROM Task WHERE Id = :t.Id].Status);
  }

  @IsTest
  static void recebimentoNaMesmaDataDaSolicitacaoPermitido() {
    Date ref = Date.today().addDays(-10);
    Task t = criarTarefaParaConcluir(Date.today().addDays(-3), ref);

    Test.startTest();
    update new Task(Id = t.Id, SOL_Data_Recebimento_Calculo__c = ref, Status = 'Completed');
    Test.stopTest();

    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :t.Id].Status);
  }

  @IsTest
  static void recebimentoPosteriorASolicitacaoPermitido() {
    Task t = criarTarefaParaConcluir(Date.today().addDays(-3), Date.today().addDays(-10));

    Test.startTest();
    update new Task(
      Id = t.Id,
      SOL_Data_Recebimento_Calculo__c = Date.today().addDays(-4),
      Status = 'Completed'
    );
    Test.stopTest();

    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :t.Id].Status);
  }

  @IsTest
  static void regraCronologicaNaoAfetaTaskComum() {
    Id opp = oppDiagnostico();
    // Task comum (sem SOL_Tipo_Tarefa__c) com recebimento ANTES da referência:
    // a VR cronológica não dispara porque o tipo não é o de acompanhamento.
    Task comum = new Task(
      Subject = 'ligar',
      WhatId = opp,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Data_Solicitacao_Calculo_Ref__c = Date.today(),
      SOL_Data_Recebimento_Calculo__c = Date.today().addDays(-15)
    );
    insert comum;

    Test.startTest();
    update new Task(Id = comum.Id, Status = 'Completed');
    Test.stopTest();

    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :comum.Id].Status);
  }

  @IsTest
  static void referenciaAusenteNaoDisparaRegraCronologica() {
    // Tarefa de acompanhamento SEM referência técnica: a regra cronológica não
    // pode gerar erro adicional — a conclusão depende só das outras VRs.
    Task t = criarTarefaParaConcluir(Date.today().addDays(7), null);

    Test.startTest();
    update new Task(
      Id = t.Id,
      SOL_Data_Recebimento_Calculo__c = Date.today().addDays(-20),
      Status = 'Completed'
    );
    Test.stopTest();

    Task depois = [SELECT Status, SOL_Data_Solicitacao_Calculo_Ref__c FROM Task WHERE Id = :t.Id];
    System.assertEquals('Completed', depois.Status);
    System.assertEquals(null, depois.SOL_Data_Solicitacao_Calculo_Ref__c);
  }

  @IsTest
  static void outrasTarefasIntactas() {
    Id opp = oppDiagnostico();

    Test.startTest();
    // Task comum (sem tipo SOL) conclui sem restrição.
    Task comum = new Task(
      Subject = 'ligar',
      WhatId = opp,
      Status = 'Open',
      ActivityDate = Date.today()
    );
    insert comum;
    update new Task(Id = comum.Id, Status = 'Completed');

    // Task de outro tipo SOL também não é afetada pelas VRs deste card.
    Task reuniao = new Task(
      Subject = 'reunião',
      WhatId = opp,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert reuniao;
    update new Task(Id = reuniao.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    Test.stopTest();

    System.assertEquals(
      'Completed',
      [SELECT Status FROM Task WHERE Id = :comum.Id].Status
    );
    System.assertEquals(
      'Completed',
      [SELECT Status FROM Task WHERE Id = :reuniao.Id].Status
    );
  }

  // ============================================================ PRAZO / CALENDÁRIO (helper)

  @IsTest
  static void prazoContaSextaComExpedienteReduzido() {
    Id bh = bhId();
    Date origem = Date.newInstance(2026, 9, 10); // quinta
    Datetime prazo = SOLBusinessHoursHelper.prazoEmDiasUteis(bh, origem, 7);
    System.assertEquals(
      Date.newInstance(2026, 9, 21),
      SOLBusinessHoursHelper.dataEm(prazo, TZ_SP),
      'A sexta 09-11 (expediente reduzido) conta como dia útil.'
    );
  }

  @IsTest
  static void prazoOrigemNoFimDeSemana() {
    Id bh = bhId();
    System.assertEquals(
      Date.newInstance(2026, 9, 22),
      SOLBusinessHoursHelper.dataEm(
        SOLBusinessHoursHelper.prazoEmDiasUteis(bh, Date.newInstance(2026, 9, 12), 7),
        TZ_SP
      ),
      'Sábado 09-12: dias úteis seguintes 14..18, 21, 22.'
    );
  }

  @IsTest
  static void activityDateSemDeslocamentoDeTimezone() {
    Id opp = oppDiagnostico();
    Date solic = Date.newInstance(2026, 9, 2); // quarta => 7º dia útil sexta 09-11

    Test.startTest();
    registrarSolicitacao(opp, solic);
    Test.stopTest();

    List<Task> ts = tarefas(opp);
    System.assertEquals(1, ts.size());
    System.assertEquals(
      Date.newInstance(2026, 9, 11),
      ts[0].ActivityDate,
      'Vencimento = data (São Paulo) do 7º dia útil, sem deslocamento GMT.'
    );
  }

  @IsTest
  static void prazoSeteDiasUteisRegressao() {
    Id bh = bhId();
    Date origem = Date.newInstance(2026, 3, 3); // terça
    Date venc = SOLBusinessHoursHelper.dataEm(
      SOLBusinessHoursHelper.prazoEmDiasUteis(bh, origem, 7),
      TZ_SP
    );
    System.assert(origem.daysBetween(venc) >= 9, '7 dias úteis = pelo menos 9 dias corridos.');
  }

  // ============================================================ FLS

  @IsTest
  static void flsDosCamposTecnicos() {
    for (String ps : new List<String>{ 'PS_SOL_Comercial', 'PS_SOL_Distribuicao_Admin' }) {
      Map<String, FieldPermissions> porCampo = new Map<String, FieldPermissions>();
      for (FieldPermissions fp : [
        SELECT Field, PermissionsRead, PermissionsEdit
        FROM FieldPermissions
        WHERE
          Parent.Name = :ps
          AND SobjectType = 'Task'
          AND Field IN ('Task.SOL_Data_Recebimento_Calculo__c', 'Task.SOL_Data_Solicitacao_Calculo_Ref__c')
      ]) {
        porCampo.put(fp.Field, fp);
      }
      FieldPermissions recebimento = porCampo.get('Task.SOL_Data_Recebimento_Calculo__c');
      FieldPermissions ref = porCampo.get('Task.SOL_Data_Solicitacao_Calculo_Ref__c');
      System.assertNotEquals(null, recebimento, ps + ' — recebimento FLS presente.');
      System.assert(
        recebimento.PermissionsRead && recebimento.PermissionsEdit,
        ps + ' — SOL_Data_Recebimento_Calculo__c editável.'
      );
      System.assertNotEquals(null, ref, ps + ' — ref FLS presente.');
      System.assert(
        ref.PermissionsRead && !ref.PermissionsEdit,
        ps + ' — SOL_Data_Solicitacao_Calculo_Ref__c somente leitura.'
      );
    }
  }

  @IsTest
  static void vendedorComercialEnxergaCamposComFLSCorreta() {
    Id perfil = [SELECT Id FROM Profile WHERE UserType = 'Standard' ORDER BY Name LIMIT 1].Id;
    User v = new User(
      FirstName = 'SOL',
      LastName = 'Calc Acomp',
      Alias = 'solca',
      Email = 'sol.calc.acomp@arnone.invalid',
      Username = 'sol.calc.acomp.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9421.test.invalid',
      ProfileId = perfil,
      TimeZoneSidKey = TZ_SP,
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert v;
      insert new PermissionSetAssignment(
        AssigneeId = v.Id,
        PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'PS_SOL_Comercial' LIMIT 1].Id
      );
    }

    Test.startTest();
    System.runAs(new User(Id = v.Id)) {
      Schema.DescribeFieldResult receb = Task.SOL_Data_Recebimento_Calculo__c.getDescribe();
      System.assert(receb.isAccessible(), 'Vendedor enxerga a data de recebimento.');
      Schema.DescribeFieldResult ref = Task.SOL_Data_Solicitacao_Calculo_Ref__c.getDescribe();
      System.assert(ref.isAccessible(), 'Vendedor enxerga a referência técnica.');
      System.assert(
        !ref.isUpdateable(),
        'A referência técnica é somente leitura para o vendedor.'
      );
      // A FLS editável de SOL_Data_Recebimento_Calculo__c (Comercial e
      // Distribuição Admin) é verificada em flsDosCamposTecnicos via
      // FieldPermissions — isUpdateable() em runtime também depende do CRUD de
      // Activity no perfil, que está fora do escopo deste permission set.
    }
    Test.stopTest();
  }
}

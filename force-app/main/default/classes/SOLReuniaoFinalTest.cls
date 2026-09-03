/**
 * CLICKUP-9422 — Card 11 — Testes da criação automática da tarefa de reunião
 * final após o recebimento do cálculo jurídico.
 *
 * O Flow after-save de Task SOL_Reuniao_Final_Apos_Calculo está ATIVO: quando a
 * Task de acompanhamento do cálculo jurídico (SOL_Tipo_Tarefa__c =
 * "Acompanhamento do cálculo jurídico") muda REALMENTE para "Completed", com
 * SOL_Data_Recebimento_Calculo__c preenchida e WhatId de Opportunity, o Apex
 * SOLReuniaoFinalService avança a Oportunidade SOL / Recuperação Tributária de
 * "Diagnóstico" para "Negociação" e cria UMA Task "Realizar reunião final"
 * (vencimento 7 dias úteis após o recebimento). ART 360, outras BUs, outros
 * tipos de Task e outras etapas ficam intactos.
 *
 * Atomicidade: avanço da etapa + criação da Task no mesmo Savepoint. As VRs de
 * Negociação (SOL_ECAC_Antes_De_Negociar etc.) NÃO são enfraquecidas — se os
 * requisitos de e-CAC não estiverem satisfeitos, a transação inteira é abortada
 * (inclusive a conclusão da Task de acompanhamento) com mensagem controlada.
 *
 * Concorrência: SELECT ... FOR UPDATE nas Tasks e Oportunidades. Transações
 * paralelas não são simuláveis em Apex — cobre-se a idempotência SEQUENCIAL.
 * FERIADO: delegado a BusinessHours.nextStartDate; sem teste automatizado direto.
 */
@IsTest
private class SOLReuniaoFinalTest {
  private static final String PRODUTO = 'Recuperação Tributária';
  private static final String TIPO_ACOMP = 'Acompanhamento do cálculo jurídico';
  private static final String TIPO_FINAL = 'Reunião final';
  private static final String SUBJECT_FINAL = 'Realizar reunião final';
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

  private static Id bhId() {
    Id v = SOLBusinessHoursHelper.businessHoursId();
    System.assertNotEquals(null, v, 'Business Hours comercial é pré-requisito.');
    return v;
  }

  private static Date vencimentoEsperado(Date recebimento) {
    return SOLBusinessHoursHelper.dataEm(
      SOLBusinessHoursHelper.prazoEmDiasUteis(bhId(), recebimento, 7),
      TZ_SP
    );
  }

  /**
   * Opp. prodOpp = produto; etapa = "Diagnóstico"/"Negociação"; oppSOL = Record
   * Type SOL; ecacOk = requisitos de e-CAC satisfeitos; owner = proprietário.
   */
  private static Id novaOpp(
    String prodOpp,
    String etapa,
    Boolean oppSOL,
    Boolean ecacOk,
    Id owner
  ) {
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
    if (ecacOk) {
      o.SOL_ECAC_Consulta_Realizada__c = true;
      o.SOL_ECAC_Data_Consulta__c = Date.today();
      o.SOL_ECAC_Resultado__c = 'Valor a recuperar';
      o.SOL_Valor_Recuperavel__c = 1000;
    }
    if (owner != null) {
      o.OwnerId = owner;
    }
    if (etapa == 'Negociação') {
      insert o;
      update new Opportunity(Id = o.Id, StageName = 'Negociação');
      return o.Id;
    }
    o.StageName = etapa;
    insert o;
    return o.Id;
  }

  private static Id oppPronta() {
    return novaOpp(PRODUTO, 'Diagnóstico', true, true, null);
  }

  /** Task de acompanhamento do cálculo (Open) vinculada a `oppId`. */
  private static Task acompanhamento(Id oppId) {
    Task t = new Task(
      Subject = 'Acompanhar recebimento do cálculo jurídico',
      WhatId = oppId,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today().addDays(3),
      SOL_Tipo_Tarefa__c = TIPO_ACOMP
    );
    insert t;
    return t;
  }

  /** Conclui a Task de acompanhamento — dispara o Flow do CLICKUP-9422. */
  private static void concluir(Id taskId, Date recebimento) {
    update new Task(
      Id = taskId,
      Status = 'Completed',
      SOL_Data_Recebimento_Calculo__c = recebimento
    );
  }

  private static Opportunity opp(Id oppId) {
    return [SELECT Id, StageName, OwnerId FROM Opportunity WHERE Id = :oppId];
  }

  private static List<Task> reunioesFinais(Id oppId) {
    return [
      SELECT
        Id,
        Subject,
        Status,
        OwnerId,
        WhatId,
        ActivityDate,
        SOL_Tipo_Tarefa__c,
        SOL_Data_Recebimento_Calculo_Ref__c,
        SOL_Data_Reuniao_Final__c
      FROM Task
      WHERE WhatId = :oppId AND SOL_Tipo_Tarefa__c = :TIPO_FINAL
    ];
  }

  // ============================================================ POSITIVO

  @IsTest
  static void fluxoPositivoCompleto() {
    Id oppId = oppPronta();
    Id owner = opp(oppId).OwnerId;
    Task acomp = acompanhamento(oppId);
    Date receb = Date.today();

    Test.startTest();
    concluir(acomp.Id, receb);
    Test.stopTest();

    System.assertEquals('Negociação', opp(oppId).StageName, 'Opp avança para Negociação.');
    List<Task> fs = reunioesFinais(oppId);
    System.assertEquals(1, fs.size(), 'Uma tarefa de reunião final.');
    System.assertEquals(SUBJECT_FINAL, fs[0].Subject);
    System.assertEquals('Open', fs[0].Status);
    System.assertEquals(oppId, fs[0].WhatId);
    System.assertEquals(owner, fs[0].OwnerId, 'Proprietário = dono atual da Oportunidade.');
    System.assertEquals(TIPO_FINAL, fs[0].SOL_Tipo_Tarefa__c);
    System.assertEquals(receb, fs[0].SOL_Data_Recebimento_Calculo_Ref__c, 'Referência = data de recebimento.');
    System.assertEquals(vencimentoEsperado(receb), fs[0].ActivityDate, '7 dias úteis após o recebimento.');
    // Card 09/10: a Task de acompanhamento foi concluída.
    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :acomp.Id].Status);
  }

  @IsTest
  static void cadeiaCard09_10_11() {
    // Regressão integrada: Card 09 grava a data → Card 10 cria a tarefa de
    // acompanhamento → concluí-la dispara o Card 11.
    Id oppId = oppPronta();
    Date receb = Date.today();

    Test.startTest();
    update new Opportunity(Id = oppId, SOL_Data_Solicitacao_Calculo__c = Date.today().addDays(-2));
    List<Task> acomps = [
      SELECT Id FROM Task WHERE WhatId = :oppId AND SOL_Tipo_Tarefa__c = :TIPO_ACOMP
    ];
    System.assertEquals(1, acomps.size(), 'Card 10 criou a tarefa de acompanhamento.');
    concluir(acomps[0].Id, receb);
    Test.stopTest();

    System.assertEquals('Negociação', opp(oppId).StageName);
    System.assertEquals(1, reunioesFinais(oppId).size());
  }

  @IsTest
  static void vencimentoSeteDiasUteis() {
    Id bh = bhId();
    // Quinta 2026-09-10 → 7º dia útil = sexta 2026-09-21 (sexta 09-11 conta,
    // mesmo com expediente reduzido).
    System.assertEquals(
      Date.newInstance(2026, 9, 21),
      SOLBusinessHoursHelper.dataEm(
        SOLBusinessHoursHelper.prazoEmDiasUteis(bh, Date.newInstance(2026, 9, 10), 7),
        TZ_SP
      )
    );
    // Sábado 2026-09-12 → 22.
    System.assertEquals(
      Date.newInstance(2026, 9, 22),
      SOLBusinessHoursHelper.dataEm(
        SOLBusinessHoursHelper.prazoEmDiasUteis(bh, Date.newInstance(2026, 9, 12), 7),
        TZ_SP
      )
    );
  }

  @IsTest
  static void vencimentoDerivaDoRecebimentoNaoDeHoje() {
    Id oppId = oppPronta();
    Task acomp = acompanhamento(oppId);
    // Recebimento numa QUARTA (2026-09-02) → 7º dia útil = sexta 2026-09-11.
    Date receb = Date.newInstance(2026, 9, 2);

    Test.startTest();
    concluir(acomp.Id, receb);
    Test.stopTest();

    List<Task> fs = reunioesFinais(oppId);
    System.assertEquals(1, fs.size());
    System.assertEquals(
      Date.newInstance(2026, 9, 11),
      fs[0].ActivityDate,
      'Vencimento = 7 dias úteis após a data real de recebimento, não Date.today().'
    );
  }

  // ============================================================ IDEMPOTÊNCIA

  @IsTest
  static void reprocessarNaoDuplicaNemReavanca() {
    Id oppId = oppPronta();
    Task acomp = acompanhamento(oppId);
    concluir(acomp.Id, Date.today());
    System.assertEquals(1, reunioesFinais(oppId).size());

    Test.startTest();
    SOLReuniaoFinalService.ResultadoReuniaoFinal r =
      SOLReuniaoFinalService.prepararReuniaoFinal(new List<Id>{ acomp.Id });
    Test.stopTest();

    System.assertEquals(0, r.tarefasCriadas, 'Reprocessamento não cria outra tarefa.');
    System.assertEquals(0, r.oportunidadesAvancadas, 'Reprocessamento não re-avança a etapa.');
    System.assertEquals(1, reunioesFinais(oppId).size());
  }

  @IsTest
  static void duasEntradasDoMesmoRegistroCriamUmaSo() {
    Id oppId = oppPronta();
    Task acomp = acompanhamento(oppId);
    update new Task(Id = acomp.Id, Status = 'Completed', SOL_Data_Recebimento_Calculo__c = Date.today());
    // A conclusão acima já disparou o Flow; reprocessa com o Id repetido.
    delete reunioesFinais(oppId); // limpa para medir a idempotência da chamada
    update new Opportunity(Id = oppId, StageName = 'Diagnóstico'); // volta para poder re-avançar

    Test.startTest();
    SOLReuniaoFinalService.prepararReuniaoFinal(new List<Id>{ acomp.Id, acomp.Id });
    Test.stopTest();

    System.assertEquals(1, reunioesFinais(oppId).size());
  }

  @IsTest
  static void tarefaJaConcluidaNaoReprocessaAoEditar() {
    Id oppId = oppPronta();
    Task acomp = acompanhamento(oppId);
    concluir(acomp.Id, Date.today());
    System.assertEquals(1, reunioesFinais(oppId).size());

    Test.startTest();
    update new Task(Id = acomp.Id, Description = 'anotação posterior');
    Test.stopTest();

    System.assertEquals(1, reunioesFinais(oppId).size(), 'Editar a Task já concluída não recria.');
  }

  // ============================================================ BULK

  @IsTest
  static void processamentoBulk() {
    List<Task> acomps = new List<Task>();
    List<Id> opps = new List<Id>();
    for (Integer i = 0; i < 10; i++) {
      Id oppId = oppPronta();
      opps.add(oppId);
      acomps.add(
        new Task(
          Subject = 'a',
          WhatId = oppId,
          OwnerId = UserInfo.getUserId(),
          Status = 'Open',
          ActivityDate = Date.today(),
          SOL_Tipo_Tarefa__c = TIPO_ACOMP
        )
      );
    }
    insert acomps;
    List<Task> concluir = new List<Task>();
    for (Task t : acomps) {
      concluir.add(
        new Task(Id = t.Id, Status = 'Completed', SOL_Data_Recebimento_Calculo__c = Date.today())
      );
    }

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    update concluir;
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    System.assertEquals(
      10,
      [SELECT COUNT() FROM Task WHERE WhatId IN :opps AND SOL_Tipo_Tarefa__c = :TIPO_FINAL]
    );
    System.assertEquals(
      10,
      [SELECT COUNT() FROM Opportunity WHERE Id IN :opps AND StageName = 'Negociação']
    );
    System.assert(soql < 20, 'SOQL não escala por registro: ' + soql);
    System.assert(dml < 8, 'DML não escala por registro: ' + dml);
  }

  // ============================================================ FORA DE ESCOPO

  @IsTest
  static void tipoDiferenteNaoDispara() {
    Id oppId = oppPronta();
    Task t = new Task(
      Subject = 'reunião comercial',
      WhatId = oppId,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert t;

    Test.startTest();
    update new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    Test.stopTest();

    System.assertEquals('Diagnóstico', opp(oppId).StageName);
    System.assertEquals(0, reunioesFinais(oppId).size());
  }

  @IsTest
  static void outraBUNaoDispara() {
    Id oppId = novaOpp(PRODUTO, 'Diagnóstico', false, false, null); // sem Record Type SOL
    Task acomp = acompanhamento(oppId);

    Test.startTest();
    concluir(acomp.Id, Date.today());
    SOLReuniaoFinalService.ResultadoReuniaoFinal r =
      SOLReuniaoFinalService.prepararReuniaoFinal(new List<Id>{ acomp.Id });
    Test.stopTest();

    System.assertEquals(0, reunioesFinais(oppId).size());
    System.assert(r.ignorados >= 1);
  }

  @IsTest
  static void art360NaoDispara() {
    Id oppId = novaOpp('ART 360', 'Diagnóstico', true, false, null);
    Task acomp = acompanhamento(oppId);

    Test.startTest();
    concluir(acomp.Id, Date.today());
    Test.stopTest();

    System.assertEquals('Diagnóstico', opp(oppId).StageName, 'ART 360 fica fora.');
    System.assertEquals(0, reunioesFinais(oppId).size());
  }

  @IsTest
  static void etapaIncompativelNaoAvanca() {
    Id oppId = novaOpp(PRODUTO, 'Negociação', true, true, null);
    Task acomp = acompanhamento(oppId);

    Test.startTest();
    concluir(acomp.Id, Date.today());
    Test.stopTest();

    System.assertEquals('Negociação', opp(oppId).StageName);
    System.assertEquals(0, reunioesFinais(oppId).size(), 'Fora de Diagnóstico: nada a fazer.');
  }

  // ============================================================ CONCLUSÃO DA REUNIÃO FINAL (VRs)

  private static Task reuniaoFinalParaConcluir(Date refRecebimento) {
    Id oppId = oppPronta();
    Task t = new Task(
      Subject = SUBJECT_FINAL,
      WhatId = oppId,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today().addDays(5),
      SOL_Tipo_Tarefa__c = TIPO_FINAL,
      SOL_Data_Recebimento_Calculo_Ref__c = refRecebimento
    );
    insert t;
    return t;
  }

  @IsTest
  static void reuniaoSemDataBloqueada() {
    Task t = reuniaoFinalParaConcluir(Date.today().addDays(-60));

    Test.startTest();
    Boolean bloqueou = false;
    try {
      update new Task(Id = t.Id, Status = 'Completed');
    } catch (DmlException e) {
      bloqueou = true;
      System.assert(e.getDmlMessage(0).containsIgnoreCase('data da reunião final'), e.getDmlMessage(0));
    }
    Test.stopTest();

    System.assert(bloqueou, 'Concluir sem SOL_Data_Reuniao_Final__c é bloqueado.');
  }

  @IsTest
  static void reuniaoDataFuturaBloqueada() {
    Task t = reuniaoFinalParaConcluir(Date.today().addDays(-60));

    Test.startTest();
    Boolean bloqueou = false;
    try {
      update new Task(
        Id = t.Id,
        SOL_Data_Reuniao_Final__c = Date.today().addDays(1),
        Status = 'Completed'
      );
    } catch (DmlException e) {
      bloqueou = true;
      System.assert(e.getDmlMessage(0).containsIgnoreCase('não pode ser futura'), e.getDmlMessage(0));
    }
    Test.stopTest();

    System.assert(bloqueou);
  }

  @IsTest
  static void reuniaoAnteriorAoRecebimentoBloqueada() {
    Task t = reuniaoFinalParaConcluir(Date.today());

    Test.startTest();
    Boolean bloqueou = false;
    try {
      update new Task(
        Id = t.Id,
        SOL_Data_Reuniao_Final__c = Date.today().addDays(-1),
        Status = 'Completed'
      );
    } catch (DmlException e) {
      bloqueou = true;
      System.assert(
        e.getDmlMessage(0).containsIgnoreCase('anterior à data de recebimento'),
        e.getDmlMessage(0)
      );
    }
    Test.stopTest();

    System.assert(bloqueou, 'Reunião anterior ao recebimento é bloqueada.');
  }

  @IsTest
  static void reuniaoMesmaDataOuPosteriorPermitida() {
    Date ref = Date.today().addDays(-10);
    Task t1 = reuniaoFinalParaConcluir(ref);
    Task t2 = reuniaoFinalParaConcluir(ref);

    Test.startTest();
    update new Task(Id = t1.Id, SOL_Data_Reuniao_Final__c = ref, Status = 'Completed');
    update new Task(Id = t2.Id, SOL_Data_Reuniao_Final__c = Date.today().addDays(-3), Status = 'Completed');
    Test.stopTest();

    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :t1.Id].Status);
    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :t2.Id].Status);
  }

  @IsTest
  static void referenciaAusenteNaoDisparaCronologia() {
    Task t = reuniaoFinalParaConcluir(null);

    Test.startTest();
    update new Task(
      Id = t.Id,
      SOL_Data_Reuniao_Final__c = Date.today().addDays(-30),
      Status = 'Completed'
    );
    Test.stopTest();

    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :t.Id].Status);
  }

  @IsTest
  static void concluirReuniaoFinalDisparaFechamentoSemAvancarEtapa() {
    // Regressão do CLICKUP-9423: concluir a reunião final agora cria a tarefa de
    // fechamento (tipo "Fechamento"), mas NÃO avança a Oportunidade além de
    // "Negociação".
    Id oppId = oppPronta();
    Task acomp = acompanhamento(oppId);
    concluir(acomp.Id, Date.today());
    Task fin = reunioesFinais(oppId)[0];

    Test.startTest();
    update new Task(Id = fin.Id, SOL_Data_Reuniao_Final__c = Date.today(), Status = 'Completed');
    Test.stopTest();

    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :fin.Id].Status);
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Task
        WHERE WhatId = :oppId AND SOL_Tipo_Tarefa__c = 'Fechamento'
      ],
      'CLICKUP-9423: uma tarefa de fechamento.'
    );
    // Nenhuma tarefa de tipo inesperado.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Task
        WHERE
          WhatId = :oppId
          AND SOL_Tipo_Tarefa__c != :TIPO_FINAL
          AND SOL_Tipo_Tarefa__c != :TIPO_ACOMP
          AND SOL_Tipo_Tarefa__c != 'Fechamento'
      ]
    );
    System.assertEquals('Negociação', opp(oppId).StageName, 'Não avança além de Negociação.');
  }

  // ============================================================ ATOMICIDADE / e-CAC

  @IsTest
  static void ecacAusenteAbortaIntegral() {
    Id oppId = novaOpp(PRODUTO, 'Diagnóstico', true, false, null); // sem e-CAC
    Task acomp = acompanhamento(oppId);

    Test.startTest();
    Boolean bloqueou = false;
    try {
      concluir(acomp.Id, Date.today());
    } catch (DmlException e) {
      bloqueou = true;
      System.assert(
        e.getDmlMessage(0).containsIgnoreCase('Negociação') ||
        e.getDmlMessage(0).containsIgnoreCase('e-CAC'),
        e.getDmlMessage(0)
      );
    }
    Test.stopTest();

    System.assert(bloqueou, 'Sem e-CAC, a conclusão da Task é abortada.');
    System.assertEquals('Diagnóstico', opp(oppId).StageName, 'Etapa não avançou.');
    System.assertEquals(0, reunioesFinais(oppId).size(), 'Nenhuma tarefa de reunião final.');
    System.assertEquals(
      'Open',
      [SELECT Status FROM Task WHERE Id = :acomp.Id].Status,
      'A conclusão da Task de acompanhamento foi desfeita (rollback integral).'
    );
  }

  @IsTest
  static void ecacAntesDeNegociarNaoFoiEnfraquecida() {
    // Confirma que a VR continua bloqueando o avanço manual sem e-CAC.
    Id oppId = novaOpp(PRODUTO, 'Diagnóstico', true, false, null);

    Test.startTest();
    Boolean bloqueou = false;
    try {
      update new Opportunity(Id = oppId, StageName = 'Negociação');
    } catch (DmlException e) {
      bloqueou = true;
    }
    Test.stopTest();

    System.assert(bloqueou, 'SOL_ECAC_Antes_De_Negociar continua ativa e sem exceção.');
  }

  @IsTest
  static void falhaForcadaNaCriacaoAbortaAtomicamente() {
    Id oppId = oppPronta();
    Task acomp = acompanhamento(oppId);
    concluir(acomp.Id, Date.today());
    delete reunioesFinais(oppId);
    update new Opportunity(Id = oppId, StageName = 'Diagnóstico');

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      SOLReuniaoFinalService.prepararReuniaoFinal(new List<Id>{ acomp.Id });
    } catch (SOLReuniaoFinalService.ReuniaoFinalException e) {
      lancou = true;
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'Falha relança ReuniaoFinalException.');
    System.assertEquals('Diagnóstico', opp(oppId).StageName);
  }

  @IsTest
  static void invocableRelancaAFalha() {
    Id oppId = oppPronta();
    Task acomp = acompanhamento(oppId);
    concluir(acomp.Id, Date.today());
    delete reunioesFinais(oppId);
    update new Opportunity(Id = oppId, StageName = 'Diagnóstico');

    SOLReuniaoFinalInvocable.Entrada e = new SOLReuniaoFinalInvocable.Entrada();
    e.taskId = acomp.Id;

    Test.startTest();
    SOLBusinessHoursHelper.overrideBusinessHours(null);
    Boolean lancou = false;
    try {
      SOLReuniaoFinalInvocable.preparar(new List<SOLReuniaoFinalInvocable.Entrada>{ e });
    } catch (SOLReuniaoFinalService.ReuniaoFinalException ex) {
      lancou = true;
      System.assertEquals(SOLReuniaoFinalService.MSG_SEM_CALENDARIO, ex.getMessage());
    }
    Test.stopTest();

    System.assert(lancou, 'O Invocable relança a falha para o Flow abortar a transação.');
  }

  @IsTest
  static void invocableEServicoIgnoramEntradasInvalidas() {
    Test.startTest();
    SOLReuniaoFinalInvocable.preparar(null);
    SOLReuniaoFinalInvocable.preparar(new List<SOLReuniaoFinalInvocable.Entrada>());
    SOLReuniaoFinalInvocable.Entrada semId = new SOLReuniaoFinalInvocable.Entrada();
    SOLReuniaoFinalInvocable.preparar(
      new List<SOLReuniaoFinalInvocable.Entrada>{ semId, null }
    );
    SOLReuniaoFinalService.ResultadoReuniaoFinal r1 = SOLReuniaoFinalService.prepararReuniaoFinal(null);
    SOLReuniaoFinalService.ResultadoReuniaoFinal r2 = SOLReuniaoFinalService.prepararReuniaoFinal(
      new List<Id>()
    );
    Test.stopTest();

    System.assertEquals(0, r1.tarefasCriadas);
    System.assertEquals(0, r2.tarefasCriadas);
    System.assertEquals(0, [SELECT COUNT() FROM Task WHERE SOL_Tipo_Tarefa__c = :TIPO_FINAL]);
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
          AND Field IN ('Task.SOL_Data_Reuniao_Final__c', 'Task.SOL_Data_Recebimento_Calculo_Ref__c')
      ]) {
        porCampo.put(fp.Field, fp);
      }
      FieldPermissions reuniao = porCampo.get('Task.SOL_Data_Reuniao_Final__c');
      FieldPermissions ref = porCampo.get('Task.SOL_Data_Recebimento_Calculo_Ref__c');
      System.assertNotEquals(null, reuniao, ps + ' — FLS de SOL_Data_Reuniao_Final__c presente.');
      System.assert(
        reuniao.PermissionsRead && reuniao.PermissionsEdit,
        ps + ' — SOL_Data_Reuniao_Final__c editável.'
      );
      System.assertNotEquals(null, ref, ps + ' — FLS da referência presente.');
      System.assert(
        ref.PermissionsRead && !ref.PermissionsEdit,
        ps + ' — SOL_Data_Recebimento_Calculo_Ref__c somente leitura.'
      );
    }
  }

  private static Id perfilStandard() {
    Map<String, Id> porNome = new Map<String, Id>();
    for (Profile p : [SELECT Id, Name FROM Profile WHERE UserType = 'Standard']) {
      porNome.put(p.Name, p.Id);
    }
    if (porNome.containsKey('Standard User')) {
      return porNome.get('Standard User');
    }
    return porNome.isEmpty() ? UserInfo.getProfileId() : porNome.values()[0];
  }

  private static User usuarioStandard(String tag) {
    return new User(
      FirstName = 'SOL',
      LastName = 'RF ' + tag,
      Alias = ('rf' + tag).left(8),
      Email = 'sol.rf.' + tag + '@arnone.invalid',
      Username = 'sol.rf.' +
        tag +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9422.test.invalid',
      ProfileId = perfilStandard(),
      TimeZoneSidKey = TZ_SP,
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private static Task reuniaoFinalPara(Id oppId, Id ownerId, Date refRecebimento) {
    Task t = new Task(
      Subject = SUBJECT_FINAL,
      WhatId = oppId,
      OwnerId = ownerId,
      Status = 'Open',
      ActivityDate = Date.today().addDays(5),
      SOL_Tipo_Tarefa__c = TIPO_FINAL,
      SOL_Data_Recebimento_Calculo_Ref__c = refRecebimento
    );
    insert t;
    return t;
  }

  private static void verificarFLSEOperacao(User u, String psName, Id oppId, Id taskId) {
    System.runAs(new User(Id = u.Id)) {
      Schema.DescribeFieldResult reuniao = Task.SOL_Data_Reuniao_Final__c.getDescribe();
      Schema.DescribeFieldResult ref = Task.SOL_Data_Recebimento_Calculo_Ref__c.getDescribe();

      System.assert(reuniao.isAccessible(), psName + ': SOL_Data_Reuniao_Final__c isAccessible.');
      System.assert(reuniao.isUpdateable(), psName + ': SOL_Data_Reuniao_Final__c isUpdateable.');
      System.assert(ref.isAccessible(), psName + ': SOL_Data_Recebimento_Calculo_Ref__c isAccessible.');
      System.assert(
        !ref.isUpdateable(),
        psName + ': SOL_Data_Recebimento_Calculo_Ref__c NÃO é isUpdateable (referência técnica).'
      );

      // Operação real: o usuário preenche a data e conclui a Task acessível.
      // Pré-requisito: o perfil precisa permitir editar Task. Se não permitir,
      // isto falha aqui e a dependência do perfil deve ser reportada.
      System.assert(
        Task.SObjectType.getDescribe().isUpdateable(),
        psName +
          ': o perfil Standard precisa de "Edit" em Activities para o vendedor/gestor concluir a tarefa.'
      );
      update new Task(
        Id = taskId,
        SOL_Data_Reuniao_Final__c = Date.today().addDays(-1),
        Status = 'Completed'
      );
    }

    Task depois = [SELECT Status, SOL_Data_Reuniao_Final__c FROM Task WHERE Id = :taskId];
    System.assertEquals('Completed', depois.Status, psName + ': Task concluída pelo próprio usuário.');
    System.assertEquals(
      Date.today().addDays(-1),
      depois.SOL_Data_Reuniao_Final__c,
      psName + ': data da reunião final preenchida pelo próprio usuário.'
    );
  }

  @IsTest
  static void flsEfetiva_comercialEGestor() {
    User vCom = usuarioStandard('com');
    User vAdm = usuarioStandard('adm');
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new List<User>{ vCom, vAdm };
      insert new List<PermissionSetAssignment>{
        new PermissionSetAssignment(
          AssigneeId = vCom.Id,
          PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'PS_SOL_Comercial' LIMIT 1].Id
        ),
        new PermissionSetAssignment(
          AssigneeId = vAdm.Id,
          PermissionSetId = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = 'PS_SOL_Distribuicao_Admin'
            LIMIT 1
          ]
          .Id
        )
      };
    }

    // Uma Opp SOL + uma Task "Reunião final" para cada usuário — Task e Opp de
    // propriedade do próprio usuário, para haver acesso ao registro.
    Id oppCom = oppPronta();
    Id oppAdm = oppPronta();
    Task tCom = reuniaoFinalPara(oppCom, vCom.Id, Date.today().addDays(-5));
    Task tAdm = reuniaoFinalPara(oppAdm, vAdm.Id, Date.today().addDays(-5));
    System.runAs(new User(Id = UserInfo.getUserId())) {
      update new Opportunity(Id = oppCom, OwnerId = vCom.Id);
      update new Opportunity(Id = oppAdm, OwnerId = vAdm.Id);
    }

    Test.startTest();
    verificarFLSEOperacao(vCom, 'PS_SOL_Comercial', oppCom, tCom.Id);
    verificarFLSEOperacao(vAdm, 'PS_SOL_Distribuicao_Admin', oppAdm, tAdm.Id);
    Test.stopTest();
  }

  // ============================================================ REGRESSÃO

  @IsTest
  static void regressao_reuniaoComercialEContato() {
    Id oppId = oppPronta();

    Test.startTest();
    // Task de reunião comercial concluída não dispara o Card 11.
    Task rc = new Task(
      Subject = 'x',
      WhatId = oppId,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert rc;
    update new Task(Id = rc.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');

    // Task de contato concluída também não.
    Task ct = new Task(
      Subject = 'ligar',
      WhatId = oppId,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Contato'
    );
    insert ct;
    update new Task(Id = ct.Id, Status = 'Completed');
    Test.stopTest();

    System.assertEquals('Diagnóstico', opp(oppId).StageName);
    System.assertEquals(0, reunioesFinais(oppId).size());
  }
}

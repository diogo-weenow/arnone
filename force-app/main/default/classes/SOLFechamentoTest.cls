/**
 * CLICKUP-9423 — Card 12 — Testes da tarefa de fechamento.
 *
 * DOIS Flows after-save ativos:
 *  - SOL_Tarefa_Fechamento_Apos_Reuniao (Task): concluir a Task "Reunião final"
 *    cria UMA Task "Realizar fechamento" (vencimento 7 dias úteis após a reunião),
 *    sem mudar a etapa da Oportunidade (fica em "Negociação").
 *  - SOL_Encerrar_Fechamento_Ganho_Perdido (Opportunity): quando a Oportunidade
 *    SOL / Recuperação Tributária vira "Ganho" ou "Perdido", conclui todas as
 *    Tasks abertas do tipo "Fechamento" dela — atômico com a mudança da Opp.
 *
 * A maioria dos testes dispara os Flows pela transição real (update). Alguns
 * chamam SOLFechamentoService diretamente para exercitar a atomicidade em modo
 * somente leitura, como nos cards anteriores.
 *
 * Concorrência: SELECT ... FOR UPDATE nas Tasks e Oportunidades. Transações
 * paralelas não são simuláveis em Apex — cobre-se a idempotência SEQUENCIAL.
 * FERIADO: delegado a BusinessHours.nextStartDate; sem teste automatizado direto.
 */
@IsTest
private class SOLFechamentoTest {
  private static final String PRODUTO = 'Recuperação Tributária';
  private static final String TIPO_REUNIAO_FINAL = 'Reunião final';
  private static final String TIPO_FECHAMENTO = 'Fechamento';
  private static final String SUBJECT_FECHAMENTO = 'Realizar fechamento';
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

  private static Date vencimentoEsperado(Date reuniao) {
    return SOLBusinessHoursHelper.dataEm(
      SOLBusinessHoursHelper.prazoEmDiasUteis(bhId(), reuniao, 7),
      TZ_SP
    );
  }

  /**
   * Opp SOL / Recuperação Tributária em "Negociação", com todos os requisitos
   * de e-CAC e de Ganho já satisfeitos (para os testes de encerramento).
   * oppSOL=false => sem Record Type SOL (outra BU). produto pode ser sobrescrito.
   */
  private static Id novaOpp(String produto, Boolean oppSOL, String etapaFinal, Id owner) {
    Account a = new Account(Name = 'Conta ' + rnd());
    insert a;
    Opportunity o = new Opportunity(
      Name = 'Op ' + rnd(),
      AccountId = a.Id,
      CloseDate = Date.today().addDays(60),
      StageName = 'Diagnóstico',
      SOL_Produto_Negocio__c = produto,
      SOL_ECAC_Consulta_Realizada__c = true,
      SOL_ECAC_Data_Consulta__c = Date.today(),
      SOL_ECAC_Resultado__c = 'Valor a recuperar',
      SOL_Valor_Recuperavel__c = 1000,
      SOL_Apresentacao_Realizada__c = true,
      SOL_Data_Apresentacao__c = Date.today(),
      SOL_Resultado_Apresentacao__c = 'Sucesso',
      SOL_Percentual_Comissao__c = 20,
      SOL_Valor_Servico__c = 5000
    );
    if (oppSOL) {
      o.RecordTypeId = rtOppSOL();
    }
    if (owner != null) {
      o.OwnerId = owner;
    }
    insert o;
    if (etapaFinal != 'Diagnóstico') {
      update new Opportunity(Id = o.Id, StageName = 'Negociação');
    }
    if (etapaFinal != 'Diagnóstico' && etapaFinal != 'Negociação') {
      update new Opportunity(Id = o.Id, StageName = etapaFinal);
    }
    return o.Id;
  }

  private static Id oppNegociacao() {
    return novaOpp(PRODUTO, true, 'Negociação', null);
  }

  private static Task reuniaoFinalTask(Id oppId, Id owner, Date reuniaoRef) {
    Task t = new Task(
      Subject = 'Realizar reunião final',
      WhatId = oppId,
      OwnerId = owner == null ? UserInfo.getUserId() : owner,
      Status = 'Open',
      ActivityDate = Date.today().addDays(3),
      SOL_Tipo_Tarefa__c = TIPO_REUNIAO_FINAL,
      SOL_Data_Recebimento_Calculo_Ref__c = reuniaoRef == null
        ? null
        : reuniaoRef.addDays(-30)
    );
    insert t;
    return t;
  }

  /** Conclui a Task "Reunião final" — dispara o Evento 1 do CLICKUP-9423. */
  private static void concluirReuniao(Id taskId, Date reuniao) {
    update new Task(
      Id = taskId,
      Status = 'Completed',
      SOL_Data_Reuniao_Final__c = reuniao
    );
  }

  private static Opportunity opp(Id oppId) {
    return [SELECT Id, StageName, OwnerId FROM Opportunity WHERE Id = :oppId];
  }

  private static List<Task> fechamentos(Id oppId) {
    return [
      SELECT
        Id,
        Subject,
        Status,
        OwnerId,
        WhatId,
        ActivityDate,
        SOL_Tipo_Tarefa__c,
        SOL_Data_Reuniao_Final_Ref__c
      FROM Task
      WHERE WhatId = :oppId AND SOL_Tipo_Tarefa__c = :TIPO_FECHAMENTO
    ];
  }

  // ============================================================ EVENTO 1 — POSITIVO

  @IsTest
  static void criaTarefaFechamento_camposEPrazo() {
    Id oppId = oppNegociacao();
    Id owner = opp(oppId).OwnerId;
    Date reuniao = Date.today();
    Task rf = reuniaoFinalTask(oppId, null, reuniao);

    Test.startTest();
    concluirReuniao(rf.Id, reuniao);
    Test.stopTest();

    List<Task> fs = fechamentos(oppId);
    System.assertEquals(1, fs.size(), 'Uma tarefa de fechamento.');
    System.assertEquals(SUBJECT_FECHAMENTO, fs[0].Subject);
    System.assertEquals('Open', fs[0].Status);
    System.assertEquals(oppId, fs[0].WhatId);
    System.assertEquals(owner, fs[0].OwnerId, 'Proprietário = dono atual da Oportunidade.');
    System.assertEquals(TIPO_FECHAMENTO, fs[0].SOL_Tipo_Tarefa__c);
    System.assertEquals(reuniao, fs[0].SOL_Data_Reuniao_Final_Ref__c, 'Referência = data da reunião.');
    System.assertEquals(vencimentoEsperado(reuniao), fs[0].ActivityDate, '7 dias úteis após a reunião.');
    System.assertEquals('Negociação', opp(oppId).StageName, 'A Oportunidade permanece em Negociação.');
  }

  @IsTest
  static void prazoDerivaDaReuniaoNaoDeHoje() {
    Id oppId = oppNegociacao();
    // Reunião numa QUARTA (2026-09-02) → 7º dia útil = sexta 2026-09-11.
    Date reuniao = Date.newInstance(2026, 9, 2);
    Task rf = reuniaoFinalTask(oppId, null, reuniao);

    Test.startTest();
    concluirReuniao(rf.Id, reuniao);
    Test.stopTest();

    List<Task> fs = fechamentos(oppId);
    System.assertEquals(1, fs.size());
    System.assertEquals(
      Date.newInstance(2026, 9, 11),
      fs[0].ActivityDate,
      'Vencimento = 7 dias úteis após a data real da reunião, não Date.today().'
    );
  }

  @IsTest
  static void vencimentoSeteDiasUteis() {
    Id bh = bhId();
    System.assertEquals(
      Date.newInstance(2026, 9, 21),
      SOLBusinessHoursHelper.dataEm(
        SOLBusinessHoursHelper.prazoEmDiasUteis(bh, Date.newInstance(2026, 9, 10), 7),
        TZ_SP
      ),
      'Quinta 09-10 → sexta 09-21 (sexta 09-11 conta, expediente reduzido).'
    );
    System.assertEquals(
      Date.newInstance(2026, 9, 22),
      SOLBusinessHoursHelper.dataEm(
        SOLBusinessHoursHelper.prazoEmDiasUteis(bh, Date.newInstance(2026, 9, 12), 7),
        TZ_SP
      ),
      'Sábado 09-12 → 22 (fim de semana pulado).'
    );
  }

  // ============================================================ EVENTO 1 — IDEMPOTÊNCIA

  @IsTest
  static void idempotencia_reprocessarNaoDuplica() {
    Id oppId = oppNegociacao();
    Date reuniao = Date.today();
    Task rf = reuniaoFinalTask(oppId, null, reuniao);

    Test.startTest();
    concluirReuniao(rf.Id, reuniao);
    SOLFechamentoService.criarTarefaFechamento(new List<Id>{ rf.Id });
    SOLFechamentoService.criarTarefaFechamento(new List<Id>{ rf.Id });
    Test.stopTest();

    System.assertEquals(1, fechamentos(oppId).size(), 'Reprocessamento não duplica.');
  }

  @IsTest
  static void duasEntradasDoMesmoRegistroCriamUmaSo() {
    Id oppId = oppNegociacao();
    Date reuniao = Date.today();
    Task rf = reuniaoFinalTask(oppId, null, reuniao);
    update new Task(Id = rf.Id, Status = 'Completed', SOL_Data_Reuniao_Final__c = reuniao);
    delete fechamentos(oppId);

    Test.startTest();
    SOLFechamentoService.criarTarefaFechamento(new List<Id>{ rf.Id, rf.Id });
    Test.stopTest();

    System.assertEquals(1, fechamentos(oppId).size());
  }

  @IsTest
  static void tarefaAnteriorEncerradaNaoDuplica() {
    Id oppId = oppNegociacao();
    Date reuniao = Date.today();
    // Tarefa de fechamento pré-existente, já concluída, da MESMA reunião.
    insert new Task(
      Subject = SUBJECT_FECHAMENTO,
      WhatId = oppId,
      OwnerId = UserInfo.getUserId(),
      Status = 'Completed',
      ActivityDate = Date.today().addDays(7),
      SOL_Tipo_Tarefa__c = TIPO_FECHAMENTO,
      SOL_Data_Reuniao_Final_Ref__c = reuniao
    );
    Task rf = reuniaoFinalTask(oppId, null, reuniao);

    Test.startTest();
    concluirReuniao(rf.Id, reuniao);
    Test.stopTest();

    List<Task> fs = fechamentos(oppId);
    System.assertEquals(1, fs.size(), 'Tarefa encerrada da mesma reunião conta — não recria.');
    System.assertEquals('Completed', fs[0].Status);
  }

  @IsTest
  static void reedicaoSemTransicaoNaoDispara() {
    Id oppId = oppNegociacao();
    Date reuniao = Date.today();
    Task rf = reuniaoFinalTask(oppId, null, reuniao);
    concluirReuniao(rf.Id, reuniao);
    System.assertEquals(1, fechamentos(oppId).size());

    Test.startTest();
    update new Task(Id = rf.Id, Description = 'anotação posterior');
    Test.stopTest();

    System.assertEquals(1, fechamentos(oppId).size(), 'Reedição sem transição não cria outra.');
  }

  // ============================================================ EVENTO 1 — BULK

  @IsTest
  static void processamentoBulk() {
    List<Id> opps = new List<Id>();
    List<Task> rfs = new List<Task>();
    for (Integer i = 0; i < 10; i++) {
      Id oppId = oppNegociacao();
      opps.add(oppId);
      rfs.add(
        new Task(
          Subject = 'r',
          WhatId = oppId,
          OwnerId = UserInfo.getUserId(),
          Status = 'Open',
          ActivityDate = Date.today(),
          SOL_Tipo_Tarefa__c = TIPO_REUNIAO_FINAL
        )
      );
    }
    insert rfs;
    List<Task> concluir = new List<Task>();
    for (Task t : rfs) {
      concluir.add(
        new Task(Id = t.Id, Status = 'Completed', SOL_Data_Reuniao_Final__c = Date.today())
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
      [SELECT COUNT() FROM Task WHERE WhatId IN :opps AND SOL_Tipo_Tarefa__c = :TIPO_FECHAMENTO]
    );
    System.assert(soql < 15, 'SOQL não escala por registro: ' + soql);
    System.assert(dml < 6, 'DML não escala por registro: ' + dml);
  }

  // ============================================================ EVENTO 1 — FORA DE ESCOPO

  @IsTest
  static void outraBUNaoDispara() {
    Id oppId = novaOpp(PRODUTO, false, 'Negociação', null); // sem Record Type SOL
    Task rf = reuniaoFinalTask(oppId, null, Date.today());

    Test.startTest();
    concluirReuniao(rf.Id, Date.today());
    SOLFechamentoService.ResultadoCriar r = SOLFechamentoService.criarTarefaFechamento(
      new List<Id>{ rf.Id }
    );
    Test.stopTest();

    System.assertEquals(0, fechamentos(oppId).size());
    System.assert(r.ignorados >= 1);
  }

  @IsTest
  static void art360NaoDispara() {
    Id oppId = novaOpp('ART 360', true, 'Negociação', null);
    Task rf = reuniaoFinalTask(oppId, null, Date.today());

    Test.startTest();
    concluirReuniao(rf.Id, Date.today());
    Test.stopTest();

    System.assertEquals(0, fechamentos(oppId).size(), 'ART 360 fica fora.');
  }

  @IsTest
  static void outroTipoDeTaskNaoDispara() {
    Id oppId = oppNegociacao();
    Task t = new Task(
      Subject = 'x',
      WhatId = oppId,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert t;

    Test.startTest();
    update new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    Test.stopTest();

    System.assertEquals(0, fechamentos(oppId).size());
  }

  @IsTest
  static void etapaIncompativelNaoCria() {
    Id oppId = novaOpp(PRODUTO, true, 'Diagnóstico', null); // ainda em Diagnóstico
    Task rf = reuniaoFinalTask(oppId, null, Date.today());

    Test.startTest();
    concluirReuniao(rf.Id, Date.today());
    Test.stopTest();

    System.assertEquals(0, fechamentos(oppId).size(), 'Fora de Negociação: não cria.');
  }

  // ============================================================ EVENTO 2 — ENCERRAMENTO

  private static Task fechamentoAberto(Id oppId, Date reuniaoRef) {
    Task t = new Task(
      Subject = SUBJECT_FECHAMENTO,
      WhatId = oppId,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today().addDays(7),
      SOL_Tipo_Tarefa__c = TIPO_FECHAMENTO,
      SOL_Data_Reuniao_Final_Ref__c = reuniaoRef
    );
    insert t;
    return t;
  }

  @IsTest
  static void conclusaoAutomaticaAoVirarGanho() {
    Id oppId = oppNegociacao();
    Task f = fechamentoAberto(oppId, Date.today().addDays(-3));

    Test.startTest();
    update new Opportunity(Id = oppId, StageName = 'Ganho');
    Test.stopTest();

    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :f.Id].Status);
    System.assertEquals('Ganho', opp(oppId).StageName);
  }

  @IsTest
  static void conclusaoAutomaticaAoVirarPerdido() {
    Id oppId = oppNegociacao();
    Task f = fechamentoAberto(oppId, Date.today().addDays(-3));

    Test.startTest();
    update new Opportunity(
      Id = oppId,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Não houve acordo na negociação'
    );
    Test.stopTest();

    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :f.Id].Status);
    System.assertEquals('Perdido', opp(oppId).StageName);
  }

  @IsTest
  static void outrasTasksIntactasNoEncerramento() {
    Id oppId = oppNegociacao();
    Task f = fechamentoAberto(oppId, Date.today().addDays(-3));
    Task comum = new Task(Subject = 'ligar', WhatId = oppId, Status = 'Open', ActivityDate = Date.today());
    insert comum;
    Task reuniao = new Task(
      Subject = 'r',
      WhatId = oppId,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert reuniao;

    Test.startTest();
    update new Opportunity(
      Id = oppId,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem retorno'
    );
    Test.stopTest();

    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :f.Id].Status);
    System.assertEquals('Open', [SELECT Status FROM Task WHERE Id = :comum.Id].Status, 'Task comum intacta.');
    System.assertEquals('Open', [SELECT Status FROM Task WHERE Id = :reuniao.Id].Status, 'Outro tipo intacto.');
  }

  @IsTest
  static void oppSemTarefaFechamentoPodeEncerrar() {
    Id oppId = oppNegociacao();

    Test.startTest();
    update new Opportunity(Id = oppId, StageName = 'Ganho');
    Test.stopTest();

    System.assertEquals('Ganho', opp(oppId).StageName, 'Sem tarefa de fechamento, o encerramento segue normalmente.');
  }

  @IsTest
  static void conclusaoManualDaTaskNaoAlteraEstagio() {
    Id oppId = oppNegociacao();
    Task f = fechamentoAberto(oppId, Date.today().addDays(-3));

    Test.startTest();
    update new Task(Id = f.Id, Status = 'Completed');
    Test.stopTest();

    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :f.Id].Status);
    System.assertEquals('Negociação', opp(oppId).StageName, 'Concluir a Task manualmente não muda a etapa.');
  }

  @IsTest
  static void reprocessarEncerramentoSemAbertasEhNoOp() {
    Id oppId = oppNegociacao();
    Task f = fechamentoAberto(oppId, Date.today().addDays(-3));
    update new Opportunity(Id = oppId, StageName = 'Ganho'); // conclui a f

    Test.startTest();
    SOLFechamentoService.ResultadoEncerrar r = SOLFechamentoService.encerrarTarefasFechamento(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(0, r.tarefasConcluidas, 'Nada aberto para concluir.');
    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :f.Id].Status);
  }

  // ============================================================ VRs GANHO/PERDIDO PRESERVADAS

  @IsTest
  static void vrsGanhoPreservadas() {
    Id oppId = oppNegociacao();
    update new Opportunity(Id = oppId, SOL_Percentual_Comissao__c = 0, SOL_Valor_Servico__c = 0);
    Task f = fechamentoAberto(oppId, Date.today().addDays(-3));

    Test.startTest();
    Boolean bloqueou = false;
    try {
      update new Opportunity(Id = oppId, StageName = 'Ganho');
    } catch (DmlException e) {
      bloqueou = true;
    }
    Test.stopTest();

    System.assert(bloqueou, 'VR de Ganho (termos financeiros) continua ativa.');
    System.assertEquals('Negociação', opp(oppId).StageName);
    System.assertEquals('Open', [SELECT Status FROM Task WHERE Id = :f.Id].Status, 'Task de fechamento intacta.');
  }

  @IsTest
  static void vrsPerdidoPreservadas() {
    Id oppId = oppNegociacao();
    Task f = fechamentoAberto(oppId, Date.today().addDays(-3));

    Test.startTest();
    Boolean bloqueou = false;
    try {
      update new Opportunity(Id = oppId, StageName = 'Perdido'); // sem motivo
    } catch (DmlException e) {
      bloqueou = true;
    }
    Test.stopTest();

    System.assert(bloqueou, 'SOL_Perdido_Exige_Motivo continua ativa.');
    System.assertEquals('Negociação', opp(oppId).StageName);
    System.assertEquals('Open', [SELECT Status FROM Task WHERE Id = :f.Id].Status);
  }

  // ============================================================ ATOMICIDADE

  @IsTest
  static void calendarioAusente_abortaEDesfazConclusaoDaReuniao() {
    Id oppId = oppNegociacao();
    Date reuniao = Date.today();
    Task rf = reuniaoFinalTask(oppId, null, reuniao);

    Test.startTest();
    SOLBusinessHoursHelper.overrideBusinessHours(null);
    Boolean bloqueou = false;
    try {
      concluirReuniao(rf.Id, reuniao);
    } catch (Exception e) {
      bloqueou = true;
      System.assert(
        e.getMessage().contains('calendário') || e.getMessage().contains('Arnone Soluções'),
        e.getMessage()
      );
    }
    Test.stopTest();

    System.assert(bloqueou, 'Calendário ausente aborta a transação.');
    System.assertEquals(0, fechamentos(oppId).size(), 'Nenhuma tarefa de fechamento.');
    System.assertEquals(
      'Open',
      [SELECT Status FROM Task WHERE Id = :rf.Id].Status,
      'A conclusão da reunião final foi desfeita (atômico).'
    );
  }

  @IsTest
  static void falhaNaCriacao_servicoAbortaAtomicamente() {
    Id oppId = oppNegociacao();
    Date reuniao = Date.today();
    Task rf = reuniaoFinalTask(oppId, null, reuniao);
    update new Task(Id = rf.Id, Status = 'Completed', SOL_Data_Reuniao_Final__c = reuniao);
    delete fechamentos(oppId);

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      SOLFechamentoService.criarTarefaFechamento(new List<Id>{ rf.Id });
    } catch (SOLFechamentoService.FechamentoException e) {
      lancou = true;
      System.assertEquals(SOLFechamentoService.MSG_FALHA_CRIAR, e.getMessage());
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'Falha na criação relança FechamentoException.');
    System.assertEquals(0, fechamentos(oppId).size());
  }

  @IsTest
  static void falhaNoEncerramento_abortaMudancaDaOpp() {
    Id oppId = oppNegociacao();
    // Task de fechamento aberta com SOL_Prazo_Contato__c: a VR
    // SOL_Resultado_Obrigatorio_Concluir bloqueia a conclusão sem resultado,
    // forçando a falha do Evento 2.
    Task f = new Task(
      Subject = SUBJECT_FECHAMENTO,
      WhatId = oppId,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today().addDays(7),
      SOL_Tipo_Tarefa__c = TIPO_FECHAMENTO,
      SOL_Data_Reuniao_Final_Ref__c = Date.today().addDays(-3),
      SOL_Prazo_Contato__c = Date.today()
    );
    insert f;

    Test.startTest();
    Boolean bloqueou = false;
    try {
      update new Opportunity(
        Id = oppId,
        StageName = 'Perdido',
        SOL_Motivo_Perda__c = 'Não houve acordo na negociação'
      );
    } catch (DmlException e) {
      bloqueou = true;
      System.assert(
        e.getDmlMessage(0).containsIgnoreCase('tarefa') || e.getDmlMessage(0).containsIgnoreCase('fechamento'),
        e.getDmlMessage(0)
      );
    }
    Test.stopTest();

    System.assert(bloqueou, 'Falha ao concluir a Task aborta a mudança da Opportunity.');
    System.assertEquals('Negociação', opp(oppId).StageName, 'A mudança da Oportunidade foi desfeita.');
    System.assertEquals('Open', [SELECT Status FROM Task WHERE Id = :f.Id].Status);
  }

  @IsTest
  static void falhaNoEncerramento_servicoAbortaAtomicamente() {
    Id oppId = oppNegociacao();
    update new Opportunity(Id = oppId, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');
    Task f = new Task(
      Subject = SUBJECT_FECHAMENTO,
      WhatId = oppId,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today().addDays(7),
      SOL_Tipo_Tarefa__c = TIPO_FECHAMENTO,
      SOL_Data_Reuniao_Final_Ref__c = Date.today().addDays(-3)
    );
    insert f;

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      SOLFechamentoService.encerrarTarefasFechamento(new List<Id>{ oppId });
    } catch (SOLFechamentoService.FechamentoException e) {
      lancou = true;
      System.assertEquals(SOLFechamentoService.MSG_FALHA_ENCERRAR, e.getMessage());
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou);
    System.assertEquals('Open', [SELECT Status FROM Task WHERE Id = :f.Id].Status);
  }

  // ============================================================ BORDAS

  @IsTest
  static void invocaveisEServicoIgnoramEntradasInvalidas() {
    Test.startTest();
    SOLFechamentoCriarInvocable.criar(null);
    SOLFechamentoCriarInvocable.criar(new List<SOLFechamentoCriarInvocable.Entrada>());
    SOLFechamentoCriarInvocable.Entrada e1 = new SOLFechamentoCriarInvocable.Entrada();
    SOLFechamentoCriarInvocable.criar(new List<SOLFechamentoCriarInvocable.Entrada>{ e1, null });

    SOLFechamentoEncerrarInvocable.encerrar(null);
    SOLFechamentoEncerrarInvocable.encerrar(new List<SOLFechamentoEncerrarInvocable.Entrada>());
    SOLFechamentoEncerrarInvocable.Entrada e2 = new SOLFechamentoEncerrarInvocable.Entrada();
    SOLFechamentoEncerrarInvocable.encerrar(new List<SOLFechamentoEncerrarInvocable.Entrada>{ e2 });

    SOLFechamentoService.ResultadoCriar r1 = SOLFechamentoService.criarTarefaFechamento(null);
    SOLFechamentoService.ResultadoCriar r2 = SOLFechamentoService.criarTarefaFechamento(new List<Id>());
    SOLFechamentoService.ResultadoEncerrar r3 = SOLFechamentoService.encerrarTarefasFechamento(null);
    SOLFechamentoService.ResultadoEncerrar r4 = SOLFechamentoService.encerrarTarefasFechamento(new List<Id>());
    Test.stopTest();

    System.assertEquals(0, r1.tarefasCriadas);
    System.assertEquals(0, r2.tarefasCriadas);
    System.assertEquals(0, r3.tarefasConcluidas);
    System.assertEquals(0, r4.tarefasConcluidas);
    System.assertEquals(0, [SELECT COUNT() FROM Task WHERE SOL_Tipo_Tarefa__c = :TIPO_FECHAMENTO]);
  }

  // ============================================================ CADEIA 09→10→11→12

  @IsTest
  static void cadeiaIntegrada_09_a_12() {
    Id oppId = oppNegociacao();
    // volta para Diagnóstico para percorrer a jornada desde o Card 10.
    update new Opportunity(Id = oppId, StageName = 'Diagnóstico');

    Test.startTest();
    // Card 09/10: registra a solicitação → cria a tarefa de acompanhamento.
    update new Opportunity(Id = oppId, SOL_Data_Solicitacao_Calculo__c = Date.today().addDays(-9));
    Task acomp = [
      SELECT Id FROM Task
      WHERE WhatId = :oppId AND SOL_Tipo_Tarefa__c = 'Acompanhamento do cálculo jurídico'
      LIMIT 1
    ];

    // Card 11: conclui o acompanhamento → avança para Negociação + cria a reunião final.
    update new Task(
      Id = acomp.Id,
      Status = 'Completed',
      SOL_Data_Recebimento_Calculo__c = Date.today().addDays(-5)
    );
    System.assertEquals('Negociação', opp(oppId).StageName);
    Task rf = [
      SELECT Id FROM Task
      WHERE WhatId = :oppId AND SOL_Tipo_Tarefa__c = :TIPO_REUNIAO_FINAL
      LIMIT 1
    ];

    // Card 12: conclui a reunião final → cria a tarefa de fechamento.
    update new Task(Id = rf.Id, Status = 'Completed', SOL_Data_Reuniao_Final__c = Date.today().addDays(-2));
    System.assertEquals(1, fechamentos(oppId).size());
    Task fech = fechamentos(oppId)[0];

    // Card 12: vira Ganho → conclui a tarefa de fechamento.
    update new Opportunity(Id = oppId, StageName = 'Ganho');
    Test.stopTest();

    System.assertEquals('Ganho', opp(oppId).StageName);
    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :fech.Id].Status);
  }

  // ============================================================ FLS EFETIVA

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
      LastName = 'Fech ' + tag,
      Alias = ('fc' + tag).left(8),
      Email = 'sol.fc.' + tag + '@arnone.invalid',
      Username = 'sol.fc.' +
        tag +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9423.test.invalid',
      ProfileId = perfilStandard(),
      TimeZoneSidKey = TZ_SP,
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private static void verificar(User u, String psName, Id oppId, Id taskId) {
    System.runAs(new User(Id = u.Id)) {
      Schema.DescribeFieldResult ref = Task.SOL_Data_Reuniao_Final_Ref__c.getDescribe();
      System.assert(ref.isAccessible(), psName + ': SOL_Data_Reuniao_Final_Ref__c isAccessible.');
      System.assert(
        !ref.isUpdateable(),
        psName + ': SOL_Data_Reuniao_Final_Ref__c NÃO é isUpdateable (referência técnica).'
      );
      System.assert(
        Task.SObjectType.getDescribe().isUpdateable(),
        psName + ': o perfil precisa de Edit em Activities para o usuário concluir a tarefa.'
      );
      // Operação real: o usuário conclui a Task de fechamento que possui.
      update new Task(Id = taskId, Status = 'Completed');
    }
    System.assertEquals(
      'Completed',
      [SELECT Status FROM Task WHERE Id = :taskId].Status,
      psName + ': Task de fechamento concluída pelo próprio usuário.'
    );
    System.assertEquals(
      'Negociação',
      opp(oppId).StageName,
      psName + ': concluir a Task manualmente não mudou a etapa.'
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

    Id oppCom = oppNegociacao();
    Id oppAdm = oppNegociacao();
    Task fCom = fechamentoAberto(oppCom, Date.today().addDays(-3));
    Task fAdm = fechamentoAberto(oppAdm, Date.today().addDays(-3));
    System.runAs(new User(Id = UserInfo.getUserId())) {
      update new Opportunity(Id = oppCom, OwnerId = vCom.Id);
      update new Opportunity(Id = oppAdm, OwnerId = vAdm.Id);
      update new Task(Id = fCom.Id, OwnerId = vCom.Id);
      update new Task(Id = fAdm.Id, OwnerId = vAdm.Id);
    }

    Test.startTest();
    verificar(vCom, 'PS_SOL_Comercial', oppCom, fCom.Id);
    verificar(vAdm, 'PS_SOL_Distribuicao_Admin', oppAdm, fAdm.Id);
    Test.stopTest();
  }

  // ============================================================ REGRESSÃO

  @IsTest
  static void regressao_reuniaoComercialContatoIntactos() {
    Id oppId = oppNegociacao();

    Test.startTest();
    Task rc = new Task(
      Subject = 'x',
      WhatId = oppId,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert rc;
    update new Task(Id = rc.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');

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

    System.assertEquals(0, fechamentos(oppId).size());
    System.assertEquals('Negociação', opp(oppId).StageName);
  }
}

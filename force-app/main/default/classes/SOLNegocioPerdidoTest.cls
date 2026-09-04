/**
 * CLICKUP-9425 — Card 14 — Testes do encerramento automático de tarefas ao
 * perder o negócio da Arnone Soluções.
 *
 * Os dois Flows do card ficam ATIVOS, então mudar o Lead para "Desqualificado /
 * Negócio perdido" ou a Oportunidade para "Perdido" já dispara o cancelamento
 * pela automação real. Vários testes exercitam esse caminho de ponta a ponta;
 * outros chamam o serviço direto para medir contagens e situações controladas —
 * a operação é idempotente, então as duas formas convivem.
 *
 * A fila usada é SINTÉTICA (queueDeveloperNameOverride), como nos cards
 * anteriores: inserir um Lead SOL dispara a distribuição (CLICKUP-9394).
 */
@IsTest
private class SOLNegocioPerdidoTest {
  private static final String FILA_SINTETICA = 'RR_Perda_SOL_9425';
  private static final String PRODUTO_RT = 'Recuperação Tributária';
  private static final String PRODUTO_ART = 'ART 360';
  private static final String CNPJ = '11222333000181';
  private static final String MOTIVO_PERDA = 'Negócio perdido';
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

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
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

  private static User vendedor(String tag) {
    return new User(
      FirstName = 'NP',
      LastName = 'Vend ' + tag,
      Alias = ('np' + tag).left(8),
      Email = 'np.' + tag + '@arnone.invalid',
      Username = 'np.' +
        tag +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9425.test.invalid',
      ProfileId = perfilStandard(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  /** Fila sintética habilitada para Lead + `qtd` vendedores ativos. */
  private static List<Id> montarFila(Integer qtd) {
    List<User> vs = new List<User>();
    for (Integer i = 0; i < qtd; i++) {
      vs.add(vendedor('a' + i + rnd().left(4)));
    }
    System.runAs(contextoAtual()) {
      if (!vs.isEmpty()) {
        insert vs;
      }
      Group fila = new Group(
        Name = 'RR Perda SOL 9425',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      List<GroupMember> gms = new List<GroupMember>();
      for (User u : vs) {
        gms.add(new GroupMember(GroupId = fila.Id, UserOrGroupId = u.Id));
      }
      if (!gms.isEmpty()) {
        insert gms;
      }
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
    List<Id> ids = new List<Id>();
    for (User u : vs) {
      ids.add(u.Id);
    }
    ids.sort();
    return ids;
  }

  private static Id rtLeadSOL() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Id rtOppSOL() {
    return Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  /** Lead SOL do produto informado, em "Captação - Contato" (padrão da org). */
  private static Lead novoLead(String produto) {
    Lead l = new Lead(
      RecordTypeId = rtLeadSOL(),
      LastName = 'Perda ' + rnd(),
      Company = 'C ' + rnd(),
      Status = 'Captação - Contato',
      CNPJ__c = CNPJ,
      SOL_Produto_Interesse__c = produto
    );
    insert l;
    return l;
  }

  private static Lead lead(Id id) {
    return [
      SELECT Id, OwnerId, Status, IsConverted, SOL_Opt_Out__c, SOL_Data_Opt_Out__c,
             SOL_Motivo_Desqualificacao__c, SOL_Produto_Interesse__c
      FROM Lead
      WHERE Id = :id
    ];
  }

  /** Marca o Lead como PERDIDO — o sinal exato do card. */
  private static void perderLead(Id leadId) {
    update new Lead(
      Id = leadId,
      Status = 'Desqualificado',
      SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA,
      SOL_Opt_Out__c = false
    );
  }

  /**
   * Opportunity SOL do produto informado, levada até `etapa`. Preenche os
   * marcos que as VRs de e-CAC/apresentação/termos exigem para avançar.
   */
  private static Id novaOpp(String produto, Boolean oppSOL, Id owner, String etapa) {
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
    if (etapa != null && etapa != 'Diagnóstico') {
      update new Opportunity(Id = o.Id, StageName = 'Negociação');
      if (etapa != 'Negociação') {
        update new Opportunity(Id = o.Id, StageName = etapa);
      }
    }
    return o.Id;
  }

  private static Opportunity opp(Id id) {
    return [
      SELECT Id, OwnerId, StageName, IsClosed, SOL_Produto_Negocio__c, SOL_Motivo_Perda__c
      FROM Opportunity
      WHERE Id = :id
    ];
  }

  /** Leva a Oportunidade para "Perdido" (a VR exige motivo da perda). */
  private static void perderOpp(Id oppId) {
    update new Opportunity(Id = oppId, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');
  }

  /** Task ABERTA de tipo técnico (ou MANUAL, quando `tipo` é null). */
  private static Task tarefa(Id whoId, Id whatId, Id owner, String tipo) {
    Task t = new Task(
      Subject = 'T ' + rnd(),
      OwnerId = owner,
      Status = 'Open',
      ActivityDate = Date.today().addDays(5),
      SOL_Tipo_Tarefa__c = tipo
    );
    if (whoId != null) {
      t.WhoId = whoId;
    }
    if (whatId != null) {
      t.WhatId = whatId;
    }
    insert t;
    return t;
  }

  private static Task recarregar(Id taskId) {
    return [
      SELECT Id, Status, IsClosed, SOL_Tipo_Tarefa__c, SOL_Motivo_Cancelamento__c,
             SOL_Cancelada_Por_Perda__c, SOL_Encerrado_Pela_Oportunidade__c, OwnerId
      FROM Task
      WHERE Id = :taskId
    ];
  }

  private static void assertCanceladaPorPerda(Id taskId, String rotulo) {
    Task t = recarregar(taskId);
    System.assertEquals('Cancelada', t.Status, rotulo + ': Status Cancelada.');
    System.assertEquals(true, t.IsClosed, rotulo + ': encerrada.');
    System.assertEquals(
      MOTIVO_PERDA,
      t.SOL_Motivo_Cancelamento__c,
      rotulo + ': motivo "Negócio perdido".'
    );
    System.assertEquals(
      true,
      t.SOL_Cancelada_Por_Perda__c,
      rotulo + ': flag de perda — distinguível de tarefa executada.'
    );
    System.assertNotEquals(
      'Completed',
      t.Status,
      rotulo + ': NUNCA aparece como executada.'
    );
  }

  // ============================================ 1. OPPORTUNITY EM CADA ETAPA

  /**
   * (1) Perda da Oportunidade em cada etapa comercial relevante — Diagnóstico,
   * Negociação e Fechamento. Em todas, todas as Tasks abertas são canceladas.
   */
  @IsTest
  static void oportunidadePerdidaEmCadaEtapaCancelaTudo() {
    List<Id> vs = montarFila(2);
    Map<String, Id> oppPorEtapa = new Map<String, Id>();
    Map<String, Id> taskPorEtapa = new Map<String, Id>();
    for (String etapa : new List<String>{ 'Diagnóstico', 'Negociação', 'Fechamento' }) {
      Id oppId = novaOpp(PRODUTO_RT, true, vs[0], etapa);
      oppPorEtapa.put(etapa, oppId);
      taskPorEtapa.put(etapa, tarefa(null, oppId, vs[0], 'Contato').Id);
    }

    Test.startTest();
    for (Id oppId : oppPorEtapa.values()) {
      perderOpp(oppId);
    }
    Test.stopTest();

    for (String etapa : oppPorEtapa.keySet()) {
      System.assertEquals('Perdido', opp(oppPorEtapa.get(etapa)).StageName, etapa + ': perdida.');
      assertCanceladaPorPerda(taskPorEtapa.get(etapa), 'Perda em ' + etapa);
    }
  }

  // ============================================ 2. LEAD ANTES DA CONVERSÃO

  /** (2) Perda do Lead antes da conversão cancela todas as tarefas dele. */
  @IsTest
  static void leadPerdidoAntesDaConversaoCancelaTudo() {
    List<Id> vs = montarFila(2);
    Lead l = novoLead(PRODUTO_RT);
    Id dono = lead(l.Id).OwnerId;
    Id t1 = tarefa(l.Id, null, dono, 'Contato').Id;
    Id t2 = tarefa(l.Id, null, dono, 'Reunião comercial').Id;

    Test.startTest();
    perderLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    System.assertEquals('Desqualificado', depois.Status);
    System.assertEquals(MOTIVO_PERDA, depois.SOL_Motivo_Desqualificacao__c);
    System.assertEquals(false, depois.IsConverted, 'Perda ANTES da conversão.');
    assertCanceladaPorPerda(t1, 'Lead perdido / Contato');
    assertCanceladaPorPerda(t2, 'Lead perdido / Reunião comercial');
  }

  // ============================================ 3. OS DOIS PRODUTOS

  /** (3) Recuperação Tributária E ART 360, no Lead e na Oportunidade. */
  @IsTest
  static void perdaCobreOsDoisProdutos() {
    List<Id> vs = montarFila(2);

    Lead leadRT = novoLead(PRODUTO_RT);
    Lead leadArt = novoLead(PRODUTO_ART);
    Id tLeadRT = tarefa(leadRT.Id, null, lead(leadRT.Id).OwnerId, 'Contato').Id;
    Id tLeadArt = tarefa(leadArt.Id, null, lead(leadArt.Id).OwnerId, 'Contato').Id;

    Id oppRT = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Id oppArt = novaOpp(PRODUTO_ART, true, vs[0], 'Negociação');
    Id tOppRT = tarefa(null, oppRT, vs[0], 'Contato').Id;
    Id tOppArt = tarefa(null, oppArt, vs[0], 'Contato').Id;

    Test.startTest();
    perderLead(leadRT.Id);
    perderLead(leadArt.Id);
    perderOpp(oppRT);
    perderOpp(oppArt);
    Test.stopTest();

    assertCanceladaPorPerda(tLeadRT, 'Lead RT');
    assertCanceladaPorPerda(tLeadArt, 'Lead ART 360');
    assertCanceladaPorPerda(tOppRT, 'Opp RT');
    assertCanceladaPorPerda(tOppArt, 'Opp ART 360');
  }

  // ============================== 4. e 5. CLASSIFICADAS + MANUAIS SEM TIPO

  /**
   * (4)(5) TODAS as abertas são canceladas com motivo e flag — as classificadas
   * e as MANUAIS sem SOL_Tipo_Tarefa__c, que continuam sem tipo (nenhum tipo
   * técnico é inventado para elas) e sem uso do Subject como classificador.
   */
  @IsTest
  static void cancelaClassificadasEManuaisSemTipo() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Id tipada = tarefa(null, oppId, vs[0], 'Reunião final').Id;
    Id manual1 = tarefa(null, oppId, vs[0], null).Id;
    Id manual2 = tarefa(null, oppId, vs[0], null).Id;

    Test.startTest();
    SOLNegocioPerdidoService.ResultadoPerda r;
    perderOpp(oppId);
    r = SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(new List<Id>{ oppId });
    Test.stopTest();

    assertCanceladaPorPerda(tipada, 'Classificada');
    assertCanceladaPorPerda(manual1, 'Manual 1');
    assertCanceladaPorPerda(manual2, 'Manual 2');
    System.assertEquals(
      null,
      recarregar(manual1).SOL_Tipo_Tarefa__c,
      'A tarefa manual continua SEM tipo técnico — nada foi inventado.'
    );
    // A 2ª chamada (acima) já não encontra nada: idempotente.
    System.assertEquals(0, r.tarefasCanceladas, 'Nada sobrou para cancelar.');
  }

  /** As manuais são contabilizadas à parte, para evidência. */
  @IsTest
  static void contabilizaTarefasManuaisSeparadamente() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    tarefa(null, oppId, vs[0], 'Contato');
    tarefa(null, oppId, vs[0], null);
    tarefa(null, oppId, vs[0], null);
    // Sem passar pelo Flow: leva a etapa e chama o serviço direto.
    update new Opportunity(Id = oppId, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');

    Test.startTest();
    SOLNegocioPerdidoService.ResultadoPerda r = SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    // O Flow já cancelou tudo na transição; a chamada direta é o 2º passe.
    System.assertEquals(1, r.negociosPerdidos, 'A Oportunidade está no escopo.');
    System.assertEquals(
      3,
      [
        SELECT COUNT()
        FROM Task
        WHERE WhatId = :oppId AND SOL_Cancelada_Por_Perda__c = TRUE
      ],
      'As três (uma tipada + duas manuais) foram canceladas por perda.'
    );
    System.assertEquals(
      2,
      [
        SELECT COUNT()
        FROM Task
        WHERE WhatId = :oppId AND SOL_Cancelada_Por_Perda__c = TRUE AND SOL_Tipo_Tarefa__c = NULL
      ],
      'Duas delas são manuais, sem tipo.'
    );
  }

  // ============================================ 6. CONCLUÍDAS/CANCELADAS

  /** (6) Tasks concluídas ou já canceladas ficam INTACTAS. */
  @IsTest
  static void concluidasEJaCanceladasFicamIntactas() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');

    Task concluida = tarefa(null, oppId, vs[0], 'Contato');
    update new Task(Id = concluida.Id, Status = 'Completed');
    Task jaCancelada = tarefa(null, oppId, vs[0], 'Contato');
    update new Task(
      Id = jaCancelada.Id,
      Status = 'Cancelada',
      SOL_Motivo_Cancelamento__c = 'Contato efetivado'
    );
    Id aberta = tarefa(null, oppId, vs[0], 'Contato').Id;

    Test.startTest();
    perderOpp(oppId);
    Test.stopTest();

    Task c = recarregar(concluida.Id);
    System.assertEquals('Completed', c.Status, 'Concluída permanece Completed.');
    System.assertEquals(false, c.SOL_Cancelada_Por_Perda__c, 'Concluída não recebe flag de perda.');
    System.assertEquals(null, c.SOL_Motivo_Cancelamento__c, 'Concluída não recebe motivo.');

    Task jc = recarregar(jaCancelada.Id);
    System.assertEquals('Cancelada', jc.Status);
    System.assertEquals(
      'Contato efetivado',
      jc.SOL_Motivo_Cancelamento__c,
      'O motivo original do cancelamento anterior é preservado.'
    );
    System.assertEquals(false, jc.SOL_Cancelada_Por_Perda__c, 'E não recebe a flag de perda.');

    assertCanceladaPorPerda(aberta, 'A única aberta');
    System.assertEquals(3, [SELECT COUNT() FROM Task WHERE WhatId = :oppId], 'Nada foi apagado.');
  }

  // ============================================ 7. e 8. PRECEDÊNCIA 9423

  /**
   * (7) Task "Fechamento" de negócio PERDIDO fica Cancelada, nunca Completed —
   * o CLICKUP-9423 não age mais em "Perdido".
   */
  @IsTest
  static void tarefaFechamentoEmPerdaFicaCanceladaNuncaCompleted() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Id fechamento = tarefa(null, oppId, vs[0], 'Fechamento').Id;

    Test.startTest();
    perderOpp(oppId);
    Test.stopTest();

    Task t = recarregar(fechamento);
    assertCanceladaPorPerda(fechamento, 'Fechamento em perda');
    System.assertEquals(
      false,
      t.SOL_Encerrado_Pela_Oportunidade__c,
      'O checkbox do 9423 NÃO é marcado em perda — quem age é o 9425.'
    );
  }

  /**
   * (8) Oportunidade GANHA mantém integralmente o comportamento do 9423: a Task
   * "Fechamento" vira Completed com SOL_Encerrado_Pela_Oportunidade__c = true, e
   * nada recebe motivo/flag de perda.
   */
  @IsTest
  static void oportunidadeGanhaMantemComportamentoDo9423() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Id fechamento = tarefa(null, oppId, vs[0], 'Fechamento').Id;

    Test.startTest();
    update new Opportunity(Id = oppId, StageName = 'Ganho');
    Test.stopTest();

    System.assertEquals('Ganho', opp(oppId).StageName);
    Task t = recarregar(fechamento);
    System.assertEquals('Completed', t.Status, 'Ganho CONCLUI a tarefa de fechamento (9423).');
    System.assertEquals(
      true,
      t.SOL_Encerrado_Pela_Oportunidade__c,
      'Ganho marca o checkbox técnico do 9423.'
    );
    System.assertEquals(
      false,
      t.SOL_Cancelada_Por_Perda__c,
      'Ganho NÃO é perda: sem flag de perda.'
    );
    System.assertEquals(null, t.SOL_Motivo_Cancelamento__c, 'Ganho NÃO grava motivo de cancelamento.');
  }

  /** Ganho também não cancela as outras tarefas abertas (escopo do 9423). */
  @IsTest
  static void ganhoNaoCancelaOutrasTarefasAbertas() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Id outra = tarefa(null, oppId, vs[0], 'Contato').Id;

    Test.startTest();
    update new Opportunity(Id = oppId, StageName = 'Ganho');
    Test.stopTest();

    Task t = recarregar(outra);
    System.assertEquals('Open', t.Status, 'Ganho não encerra tarefas fora do escopo do 9423.');
    System.assertEquals(false, t.SOL_Cancelada_Por_Perda__c);
  }

  // ============================================ 9. e 10. OPT-OUT / LEAD

  /**
   * (9) O opt-out (CLICKUP-9418) mantém comportamento e motivo próprios: motivo
   * do Lead "Opt-out", motivo do cancelamento "Opt-out" e NENHUMA flag de perda.
   */
  @IsTest
  static void optOutMantemComportamentoEMotivoProprios() {
    List<Id> vs = montarFila(2);
    Lead l = novoLead(PRODUTO_RT);
    Id dono = lead(l.Id).OwnerId;
    Id contato = tarefa(l.Id, null, dono, 'Contato').Id;

    Test.startTest();
    SOLDistribuicaoService.registrarOptOut(new List<Id>{ l.Id });
    Test.stopTest();

    Lead depois = lead(l.Id);
    System.assertEquals('Desqualificado', depois.Status);
    System.assertEquals(true, depois.SOL_Opt_Out__c, 'Opt-out marcado.');
    System.assertEquals(
      'Opt-out',
      depois.SOL_Motivo_Desqualificacao__c,
      'O motivo do opt-out NÃO é sobrescrito por "Negócio perdido".'
    );

    Task t = recarregar(contato);
    System.assertEquals('Cancelada', t.Status);
    System.assertEquals(
      'Opt-out',
      t.SOL_Motivo_Cancelamento__c,
      'Cancelamento por opt-out mantém o motivo próprio.'
    );
    System.assertEquals(
      false,
      t.SOL_Cancelada_Por_Perda__c,
      'Opt-out NÃO é perda de negócio: sem flag de perda.'
    );
  }

  /** O encerramento por perda NÃO alcança um Lead desqualificado por opt-out. */
  @IsTest
  static void servicoDePerdaIgnoraLeadEmOptOut() {
    List<Id> vs = montarFila(2);
    Lead l = novoLead(PRODUTO_RT);
    SOLDistribuicaoService.registrarOptOut(new List<Id>{ l.Id });
    Id aberta = tarefa(l.Id, null, lead(l.Id).OwnerId, 'Reunião comercial').Id;

    Test.startTest();
    SOLNegocioPerdidoService.ResultadoPerda r = SOLNegocioPerdidoService.encerrarPorLeadPerdido(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.negociosPerdidos, 'Opt-out não é perda de negócio.');
    System.assertEquals(1, r.ignorados);
    System.assertEquals('Open', recarregar(aberta).Status, 'A tarefa não foi tocada pelo 9425.');
  }

  /**
   * (10) "Desqualificado" SEM o sinal exato de perda não dispara o encerramento
   * — e também não ganha exceção indevida em nenhuma regra.
   */
  @IsTest
  static void desqualificadoSemSinalExatoNaoDispara() {
    List<Id> vs = montarFila(2);

    // (a) Lead que segue na cadência, sem desqualificação nenhuma.
    Lead naCadencia = novoLead(PRODUTO_RT);
    Id tNaCadencia = tarefa(naCadencia.Id, null, lead(naCadencia.Id).OwnerId, 'Contato').Id;
    // (b) Lead em opt-out — desqualificado, mas por outro motivo.
    Lead comOptOut = novoLead(PRODUTO_RT);
    Id tComOptOut = tarefa(comOptOut.Id, null, lead(comOptOut.Id).OwnerId, 'Contato').Id;
    // (c) Leads para as tentativas incoerentes, que a VR do D2 agora barra.
    Lead semMotivo = novoLead(PRODUTO_RT);
    Lead perdaComFlag = novoLead(PRODUTO_RT);

    Test.startTest();
    // Desde o D2 da homologação E2E os dois estados incoerentes nem chegam a
    // existir: a VR SOL_Desqualificacao_Coerente barra a gravação. O serviço
    // continua exigindo o sinal exato, e agora o banco também.
    Boolean bloqueouSemMotivo = false;
    try {
      update new Lead(Id = semMotivo.Id, Status = 'Desqualificado');
    } catch (DmlException e) {
      bloqueouSemMotivo = true;
    }
    Boolean bloqueouPerdaComFlag = false;
    try {
      update new Lead(
        Id = perdaComFlag.Id,
        Status = 'Desqualificado',
        SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA,
        SOL_Opt_Out__c = true
      );
    } catch (DmlException e) {
      bloqueouPerdaComFlag = true;
    }

    // Os dois estados que EXISTEM de verdade sem ser perda seguem ignorados.
    SOLDistribuicaoService.registrarOptOut(new List<Id>{ comOptOut.Id });
    SOLNegocioPerdidoService.ResultadoPerda r = SOLNegocioPerdidoService.encerrarPorLeadPerdido(
      new List<Id>{ naCadencia.Id, comOptOut.Id }
    );
    Test.stopTest();

    System.assert(bloqueouSemMotivo, 'Desqualificar sem motivo é barrado na gravação.');
    System.assert(
      bloqueouPerdaComFlag,
      'Perda com a flag de opt-out ligada é barrada na gravação.'
    );
    System.assertEquals(0, r.negociosPerdidos, 'Nenhum dos dois tem o sinal EXATO de perda.');
    System.assertEquals(2, r.ignorados);
    System.assertEquals(
      'Open',
      recarregar(tNaCadencia).Status,
      'Lead na cadência: tarefa intacta.'
    );
    System.assertEquals(
      'Cancelada',
      recarregar(tComOptOut).Status,
      'A tarefa do opt-out foi cancelada pelo 9418 — não pela perda.'
    );
    System.assert(
      recarregar(tComOptOut).SOL_Cancelada_Por_Perda__c != true,
      'E sem a marca de cancelamento por perda.'
    );
  }

  // ============================================ 11. SAÍDA DE "RECEBIDO - MQL"

  /**
   * (11) Sair de "Recebido - MQL" em Recuperação Tributária sem compromisso é
   * permitido SOMENTE para opt-out ou para perda devidamente identificada;
   * qualquer outra saída manual segue bloqueada pela VR
   * SOL_Recuperacao_Exige_Compromisso.
   */
  @IsTest
  static void saidaDeRecebidoMqlSoParaOptOutOuPerda() {
    montarFila(2);

    Lead paraPerder = novoLead(PRODUTO_RT);
    update new Lead(Id = paraPerder.Id, Status = 'Recebido - MQL');
    Lead paraBloquear = novoLead(PRODUTO_RT);
    update new Lead(Id = paraBloquear.Id, Status = 'Recebido - MQL');
    Lead paraOptOut = novoLead(PRODUTO_RT);
    update new Lead(Id = paraOptOut.Id, Status = 'Recebido - MQL');

    Test.startTest();
    // (a) PERDA devidamente identificada: permitida.
    perderLead(paraPerder.Id);

    // (b) Qualquer outra saída manual: BLOQUEADA pela VR do compromisso.
    // Usamos "Reunião Agendada - SQL" porque "Qualificado" já é barrado antes
    // pelo Flow de avanço (CLICKUP-9419), com outra mensagem — o que mascararia
    // o que este teste quer isolar.
    Boolean bloqueou = false;
    try {
      update new Lead(Id = paraBloquear.Id, Status = 'Reunião Agendada - SQL');
    } catch (DmlException e) {
      bloqueou = e.getMessage().containsIgnoreCase('compromisso');
    }

    // (c) Desqualificado sem o motivo de perda: também BLOQUEADO. Desde o D2 da
    // homologação E2E duas regras cobrem este desvio — a do compromisso e a de
    // coerência do motivo —, e a plataforma reporta a primeira que avaliar.
    Boolean bloqueouSemMotivo = false;
    try {
      update new Lead(Id = paraBloquear.Id, Status = 'Desqualificado');
    } catch (DmlException e) {
      bloqueouSemMotivo =
        e.getMessage().containsIgnoreCase('compromisso') ||
        e.getMessage().containsIgnoreCase('incoerente');
    }

    // (d) OPT-OUT: permitido, como antes do card.
    SOLDistribuicaoService.registrarOptOut(new List<Id>{ paraOptOut.Id });
    Test.stopTest();

    System.assertEquals(
      'Desqualificado',
      lead(paraPerder.Id).Status,
      'Perda identificada sai de "Recebido - MQL" sem compromisso.'
    );
    System.assert(bloqueou, 'Saída manual para "Qualificado" segue bloqueada.');
    System.assert(bloqueouSemMotivo, 'Desqualificação sem motivo de perda segue bloqueada.');
    System.assertEquals(
      'Opt-out',
      lead(paraOptOut.Id).SOL_Motivo_Desqualificacao__c,
      'A exceção do opt-out (CLICKUP-9418) continua valendo.'
    );
  }

  // ============================================ 12. OUTRA BU

  /** (12) Outra BU / outro produto: ignorados. */
  @IsTest
  static void outraBUEProdutoForaDoEscopoIgnorados() {
    List<Id> vs = montarFila(2);
    // Opportunity SEM Record Type SOL.
    Id outraBU = novaOpp(PRODUTO_RT, false, vs[0], 'Negociação');
    Id tOutraBU = tarefa(null, outraBU, vs[0], 'Contato').Id;
    // Record Type SOL, mas produto fora dos dois previstos.
    Id semProduto = novaOpp(null, true, vs[0], 'Negociação');
    Id tSemProduto = tarefa(null, semProduto, vs[0], 'Contato').Id;

    Test.startTest();
    update new Opportunity(Id = outraBU, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');
    update new Opportunity(
      Id = semProduto,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem retorno'
    );
    SOLNegocioPerdidoService.ResultadoPerda r = SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
      new List<Id>{ outraBU, semProduto }
    );
    Test.stopTest();

    System.assertEquals(0, r.negociosPerdidos, 'Fora do escopo: nada processado.');
    System.assertEquals(2, r.ignorados);
    System.assertEquals('Open', recarregar(tOutraBU).Status, 'Outra BU intacta.');
    System.assertEquals('Open', recarregar(tSemProduto).Status, 'Produto fora do escopo intacto.');
  }

  // ============================================ 13. PERDA SEM TAREFAS

  /** (13) Perda sem nenhuma tarefa aberta: a mudança do pai segue normalmente. */
  @IsTest
  static void perdaSemTarefasSegueNormalmente() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Lead l = novoLead(PRODUTO_ART);

    Test.startTest();
    perderOpp(oppId);
    perderLead(l.Id);
    SOLNegocioPerdidoService.ResultadoPerda rOpp = SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
      new List<Id>{ oppId }
    );
    SOLNegocioPerdidoService.ResultadoPerda rLead = SOLNegocioPerdidoService.encerrarPorLeadPerdido(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals('Perdido', opp(oppId).StageName, 'A perda da Opp foi salva.');
    System.assertEquals('Desqualificado', lead(l.Id).Status, 'A perda do Lead foi salva.');
    System.assertEquals(1, rOpp.negociosPerdidos);
    System.assertEquals(0, rOpp.tarefasCanceladas, 'Sem tarefa aberta: nada a cancelar.');
    System.assertEquals(1, rLead.negociosPerdidos);
    System.assertEquals(0, rLead.tarefasCanceladas);
  }

  // ============================== 14. IDEMPOTÊNCIA / BULK / FALHA ATÔMICA

  /** (14a) Idempotência: reprocessar a perda não altera o que já foi gravado. */
  @IsTest
  static void idempotenciaDoEncerramento() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Id t = tarefa(null, oppId, vs[0], 'Contato').Id;
    update new Opportunity(Id = oppId, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');

    Test.startTest();
    SOLNegocioPerdidoService.ResultadoPerda r1 = SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
      new List<Id>{ oppId }
    );
    Datetime depoisDoPrimeiro = [SELECT LastModifiedDate FROM Task WHERE Id = :t].LastModifiedDate;
    SOLNegocioPerdidoService.ResultadoPerda r2 = SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
      new List<Id>{ oppId }
    );
    SOLNegocioPerdidoService.ResultadoPerda r3 = SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    assertCanceladaPorPerda(t, 'Após reprocessamento');
    System.assertEquals(0, r2.tarefasCanceladas, '2ª passada não cancela nada.');
    System.assertEquals(0, r3.tarefasCanceladas, '3ª passada também não.');
    System.assertEquals(
      depoisDoPrimeiro,
      [SELECT LastModifiedDate FROM Task WHERE Id = :t].LastModifiedDate,
      'A Task não é regravada nas passadas seguintes.'
    );
  }

  /** (14b) Bulk: muitos negócios perdidos numa passada, sem SOQL/DML em laço. */
  @IsTest
  static void processamentoBulk() {
    List<Id> vs = montarFila(3);
    List<Id> opps = new List<Id>();
    List<Task> tarefas = new List<Task>();
    for (Integer i = 0; i < 10; i++) {
      Id oppId = novaOpp(Math.mod(i, 2) == 0 ? PRODUTO_RT : PRODUTO_ART, true, vs[0], 'Negociação');
      opps.add(oppId);
      tarefas.add(
        new Task(
          Subject = 'b' + i,
          WhatId = oppId,
          OwnerId = vs[0],
          Status = 'Open',
          ActivityDate = Date.today()
        )
      );
    }
    insert tarefas;
    List<Opportunity> perder = new List<Opportunity>();
    for (Id oppId : opps) {
      perder.add(
        new Opportunity(Id = oppId, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno')
      );
    }
    update perder;

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    SOLNegocioPerdidoService.ResultadoPerda r = SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
      opps
    );
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    System.assertEquals(10, r.negociosPerdidos, 'As 10 estão no escopo.');
    System.assert(soql <= 3, 'Sem SOQL em laço: ' + soql);
    System.assert(dml <= 3, 'Sem DML em laço: ' + dml);
    System.assertEquals(
      10,
      [SELECT COUNT() FROM Task WHERE WhatId IN :opps AND SOL_Cancelada_Por_Perda__c = TRUE],
      'Todas as 10 tarefas foram canceladas pela perda (pelo Flow, na transição).'
    );
  }

  /**
   * (14c) Falha ATÔMICA: se o cancelamento não puder ser gravado, o serviço
   * relança a exceção controlada e NADA é alterado. No Flow, com
   * flowTransactionModel = CurrentTransaction, essa exceção desfaz a própria
   * perda (a transição do pai) — comprovado no E2E, fora de transação de teste.
   */
  @IsTest
  static void falhaNoCancelamentoRelancaEDesfazTudo() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Id t = tarefa(null, oppId, vs[0], 'Contato').Id;
    update new Opportunity(Id = oppId, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');
    // O Flow já cancelou na transição; reabre para exercitar a falha.
    update new Task(
      Id = t,
      Status = 'Open',
      SOL_Cancelada_Por_Perda__c = false,
      SOL_Motivo_Cancelamento__c = null
    );

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    String mensagem = null;
    try {
      SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(new List<Id>{ oppId });
    } catch (SOLNegocioPerdidoService.NegocioPerdidoException e) {
      lancou = true;
      mensagem = e.getMessage();
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'A falha é RELANÇADA (o Flow aborta a perda).');
    System.assertEquals(
      SOLNegocioPerdidoService.MSG_FALHA_OPORTUNIDADE,
      mensagem,
      'Mensagem controlada, sem detalhe técnico.'
    );
    Task depois = recarregar(t);
    System.assertEquals('Open', depois.Status, 'Nada foi gravado na Task.');
    System.assertEquals(false, depois.SOL_Cancelada_Por_Perda__c);
    System.assertEquals(null, depois.SOL_Motivo_Cancelamento__c);
  }

  /** A mesma atomicidade na entrada do Lead, com a sua própria mensagem. */
  @IsTest
  static void falhaNoCancelamentoDoLeadRelancaMensagemPropria() {
    montarFila(2);
    Lead l = novoLead(PRODUTO_RT);
    perderLead(l.Id);
    // Reabre uma tarefa para que exista gravação a falhar (sem tarefa aberta o
    // serviço retorna sem DML, que é o caminho de "perda sem tarefas").
    Task reaberta = [SELECT Id FROM Task WHERE WhoId = :l.Id LIMIT 1];
    update new Task(
      Id = reaberta.Id,
      Status = 'Open',
      SOL_Cancelada_Por_Perda__c = false,
      SOL_Motivo_Cancelamento__c = null
    );

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    String mensagem = null;
    try {
      SOLNegocioPerdidoService.encerrarPorLeadPerdido(new List<Id>{ l.Id });
    } catch (SOLNegocioPerdidoService.NegocioPerdidoException e) {
      lancou = true;
      mensagem = e.getMessage();
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'A falha é RELANÇADA na entrada do Lead.');
    System.assertEquals(SOLNegocioPerdidoService.MSG_FALHA_LEAD, mensagem);
  }

  // ============================== 15. NADA DE AUTOMAÇÃO DEPOIS DA PERDA

  /**
   * (15) Tentativa de reprocessamento DEPOIS da perda não cria nem altera
   * tarefas: cada serviço do Grupo B relê o estado do Lead e para.
   */
  @IsTest
  static void reprocessamentoAposPerdaNaoCriaNemAlteraTarefas() {
    List<Id> vs = montarFila(3);
    Lead l = novoLead(PRODUTO_RT);
    Id dono = lead(l.Id).OwnerId;
    perderLead(l.Id);
    Integer tarefasAntes = [SELECT COUNT() FROM Task WHERE WhoId = :l.Id];

    Test.startTest();
    // Distribuição inicial / reprocessamento (CLICKUP-9394).
    SOLDistribuicaoService.Resultado rDist = SOLDistribuicaoService.distribuir(new List<Id>{ l.Id });
    // Reatribuição por falta de contato (CLICKUP-9400).
    SOLDistribuicaoService.ResultadoReatribuicao rReat = SOLDistribuicaoService.reatribuirPorFaltaDeContato(
      new List<Id>{ l.Id }
    );
    // Contato efetivado (CLICKUP-9417) — alimentaria o prazo de 30 dias.
    SOLDistribuicaoService.ResultadoContatoEfetivado rContato = SOLDistribuicaoService.registrarContatoEfetivado(
      new List<Id>{ l.Id }
    );
    // Tarefa de reunião comercial (CLICKUP-9401) e de procuração (CLICKUP-9426).
    SOLReuniaoComercialService.ResultadoReuniaoComercial rReuniao = SOLReuniaoComercialService.criarTarefaReuniao(
      new List<Id>{ l.Id }
    );
    SOLProcuracaoAcompanhamentoService.ResultadoAcompanhamento rProc = SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, rDist.distribuidos, 'Não redistribui negócio perdido.');
    System.assertEquals(0, rReat.reatribuidos, 'Não reatribui negócio perdido.');
    System.assertEquals(0, rContato.leadsSinalizados, 'Não sinaliza contato efetivado.');
    System.assertEquals(0, rReuniao.tarefasCriadas, 'Não cria tarefa de reunião comercial.');
    System.assertEquals(0, rProc.tarefasCriadas, 'Não cria tarefa de acompanhamento.');
    System.assertEquals(
      tarefasAntes,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id],
      'NENHUMA tarefa nova depois da perda.'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND IsClosed = false],
      'E nenhuma tarefa aberta sobrou.'
    );
    System.assertEquals(dono, lead(l.Id).OwnerId, 'O proprietário do Lead não mudou.');
    System.assertEquals(
      MOTIVO_PERDA,
      lead(l.Id).SOL_Motivo_Desqualificacao__c,
      'E o motivo da perda não foi sobrescrito.'
    );
  }

  /** Os serviços da Oportunidade também param depois da perda. */
  @IsTest
  static void servicosDaOportunidadeParamDepoisDaPerda() {
    List<Id> vs = montarFila(3);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Diagnóstico');
    perderOpp(oppId);

    Test.startTest();
    SOLAcompanhamentoCalculoService.ResultadoAcompanhamento rAcomp = SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(
      0,
      rAcomp.tarefasCriadas,
      'Nenhuma tarefa de acompanhamento do cálculo depois da perda.'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhatId = :oppId AND IsClosed = false],
      'Nenhuma tarefa aberta na Oportunidade perdida.'
    );
  }

  // ================== DISTRIBUIÇÃO x PERDA (lock e revalidação pós-lock)
  //
  // `SOLDistribuicaoService.distribuir` lê os Leads com FOR UPDATE (depois de
  // travar o singleton — ordem de locks preservada) e revalida
  // `SOLNegocioPerdidoService.leadPerdido` sobre esses dados travados, antes de
  // gravar o Lead ou criar a tarefa de 1ª ligação.
  //
  // CONCORRÊNCIA PARALELA REAL NÃO É SIMULÁVEL EM APEX: a garantia de que a
  // perda e a distribuição não se cruzam vem do `FOR UPDATE` (uma das duas
  // transações espera a outra terminar). O que os testes abaixo comprovam é a
  // outra metade — a REVALIDAÇÃO e os estados SEQUENCIAIS resultantes.

  /** Snapshot dos campos de distribuição, para provar que nada foi tocado. */
  private static Lead leadDistribuicao(Id id) {
    return [
      SELECT Id, OwnerId, Status, SOL_Opt_Out__c, SOL_Motivo_Desqualificacao__c,
             SOL_Status_Distribuicao__c, SOL_Data_Distribuicao__c,
             SOL_Erro_Distribuicao__c, SOL_Data_Inicio_Ciclo_Contato__c,
             SOL_Status_Reatribuicao__c
      FROM Lead
      WHERE Id = :id
    ];
  }

  /**
   * (1) `distribuir` ignora Lead JÁ PERDIDO sem alterar Owner nem os campos de
   * distribuição, e sem criar tarefa.
   *
   * O Lead é deixado em `Erro` de propósito — é o estado que o Batch de
   * reprocessamento (CLICKUP-9394) procura. Assim o teste isola a guarda de
   * PERDA: se ele passasse por já estar "Distribuido", passaria pelo motivo
   * errado.
   */
  @IsTest
  static void distribuirIgnoraLeadPerdidoSemAlterarNada() {
    List<Id> vs = montarFila(3);
    Lead l = novoLead(PRODUTO_RT);
    // Estado que o reprocessamento reprocessaria.
    update new Lead(
      Id = l.Id,
      SOL_Status_Distribuicao__c = 'Erro',
      SOL_Erro_Distribuicao__c = 'falha anterior'
    );
    perderLead(l.Id);

    Lead antes = leadDistribuicao(l.Id);
    Integer tarefasAntes = [SELECT COUNT() FROM Task WHERE WhoId = :l.Id];

    Test.startTest();
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(new List<Id>{ l.Id });
    Test.stopTest();

    System.assertEquals(0, r.distribuidos, 'Negócio perdido não é distribuído.');
    System.assertEquals(0, r.emFallback, 'E não cai em fallback.');
    System.assertEquals(1, r.ignorados, 'É contado como ignorado.');

    Lead depois = leadDistribuicao(l.Id);
    System.assertEquals(antes.OwnerId, depois.OwnerId, 'Proprietário intacto.');
    System.assertEquals(
      antes.SOL_Status_Distribuicao__c,
      depois.SOL_Status_Distribuicao__c,
      'Status da distribuição intacto.'
    );
    System.assertEquals(
      antes.SOL_Data_Distribuicao__c,
      depois.SOL_Data_Distribuicao__c,
      'Data da distribuição intacta.'
    );
    System.assertEquals(
      antes.SOL_Erro_Distribuicao__c,
      depois.SOL_Erro_Distribuicao__c,
      'Mensagem de erro intacta.'
    );
    System.assertEquals(
      antes.SOL_Data_Inicio_Ciclo_Contato__c,
      depois.SOL_Data_Inicio_Ciclo_Contato__c,
      'Ciclo de contato NÃO é reaberto.'
    );
    System.assertEquals(
      antes.SOL_Status_Reatribuicao__c,
      depois.SOL_Status_Reatribuicao__c,
      'Status de reatribuição intacto.'
    );
    System.assertEquals(
      MOTIVO_PERDA,
      depois.SOL_Motivo_Desqualificacao__c,
      'O motivo da perda não foi sobrescrito.'
    );
    System.assertEquals(
      tarefasAntes,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id],
      'NENHUMA tarefa nova (nem a de 1ª ligação).'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND IsClosed = false],
      'E nenhuma aberta sobrou.'
    );
  }

  /**
   * (2) O caminho de CONFIGURAÇÃO INVÁLIDA — que cai em `marcarErro` — também
   * não altera Lead perdido. `singletonKeyOverride` aponta para uma chave
   * inexistente, o que faz `bloquearSingleton` lançar `SingletonAusenteException`
   * e a distribuição ir para o tratamento de erro.
   */
  @IsTest
  static void marcarErroNaoAlteraLeadPerdido() {
    List<Id> vs = montarFila(3);
    Lead perdido = novoLead(PRODUTO_RT);
    Lead ativo = novoLead(PRODUTO_ART);
    for (Id id : new List<Id>{ perdido.Id, ativo.Id }) {
      update new Lead(Id = id, SOL_Status_Distribuicao__c = 'Pendente');
    }
    perderLead(perdido.Id);

    Lead antesPerdido = leadDistribuicao(perdido.Id);

    Test.startTest();
    SOLDistribuicaoService.singletonKeyOverride = 'RR_CHAVE_INEXISTENTE_9425';
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(
      new List<Id>{ perdido.Id, ativo.Id }
    );
    SOLDistribuicaoService.singletonKeyOverride = null;
    Test.stopTest();

    // O Lead ATIVO recebe o tratamento de erro normal.
    Lead depoisAtivo = leadDistribuicao(ativo.Id);
    System.assertEquals(
      'Erro',
      depoisAtivo.SOL_Status_Distribuicao__c,
      'O Lead ativo é marcado com Erro pelo tratamento de configuração.'
    );
    System.assertEquals(1, r.comErro, 'Só o Lead ativo entra na contagem de erro.');
    System.assert(!r.mensagens.isEmpty(), 'A mensagem controlada é registrada.');

    // O Lead PERDIDO fica intocado.
    Lead depoisPerdido = leadDistribuicao(perdido.Id);
    System.assertEquals(antesPerdido.OwnerId, depoisPerdido.OwnerId, 'Proprietário intacto.');
    System.assertEquals(
      'Pendente',
      depoisPerdido.SOL_Status_Distribuicao__c,
      'Status da distribuição intacto — não virou "Erro".'
    );
    System.assertEquals(
      antesPerdido.SOL_Data_Distribuicao__c,
      depoisPerdido.SOL_Data_Distribuicao__c,
      'Data da distribuição intacta.'
    );
    System.assertEquals(
      antesPerdido.SOL_Erro_Distribuicao__c,
      depoisPerdido.SOL_Erro_Distribuicao__c,
      'Mensagem de erro intacta.'
    );
    System.assertEquals(
      MOTIVO_PERDA,
      depoisPerdido.SOL_Motivo_Desqualificacao__c,
      'O motivo da perda não foi sobrescrito.'
    );
  }

  /** O isolamento do opt-out em `marcarErro` também é preservado. */
  @IsTest
  static void marcarErroNaoAlteraLeadEmOptOut() {
    montarFila(3);
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(Id = l.Id, SOL_Status_Distribuicao__c = 'Pendente');
    SOLDistribuicaoService.registrarOptOut(new List<Id>{ l.Id });
    Lead antes = leadDistribuicao(l.Id);

    Test.startTest();
    SOLDistribuicaoService.singletonKeyOverride = 'RR_CHAVE_INEXISTENTE_9425';
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(new List<Id>{ l.Id });
    SOLDistribuicaoService.singletonKeyOverride = null;
    Test.stopTest();

    System.assertEquals(0, r.comErro, 'Lead em opt-out não entra na contagem de erro.');
    Lead depois = leadDistribuicao(l.Id);
    System.assertEquals(antes.OwnerId, depois.OwnerId, 'Proprietário intacto.');
    System.assertEquals(
      'Pendente',
      depois.SOL_Status_Distribuicao__c,
      'Quem pediu opt-out não é devolvido à fila com status de erro.'
    );
    System.assertEquals(
      'Opt-out',
      depois.SOL_Motivo_Desqualificacao__c,
      'O motivo do opt-out é preservado.'
    );
  }

  /**
   * (3) Distribuição NORMAL, FALLBACK e REPROCESSAMENTO seguem funcionando
   * depois do lock e da revalidação — nenhum caminho legítimo foi bloqueado.
   */
  @IsTest
  static void distribuicaoNormalFallbackEReprocessamentoIntactos() {
    List<Id> vs = montarFila(3);

    // (a) NORMAL: Lead ativo em "Pendente" recebe um vendedor da fila e a
    //     tarefa de 1ª ligação.
    Lead normal = novoLead(PRODUTO_RT);
    update new Lead(
      Id = normal.Id,
      SOL_Status_Distribuicao__c = 'Pendente',
      SOL_Data_Inicio_Ciclo_Contato__c = null
    );
    // A inserção do Lead SOL já dispara a distribuição pelo Flow, que cria uma
    // "1ª Ligação". A chamada explícita abaixo é um RE-processamento, então o
    // que se mede é o INCREMENTO, não o total.
    Integer ligacoesAntes = [
      SELECT COUNT()
      FROM Task
      WHERE WhoId = :normal.Id AND Subject = '1ª Ligação'
    ];

    // (b) REPROCESSAMENTO: Lead ativo em "Erro" volta a ser distribuído.
    Lead reproc = novoLead(PRODUTO_ART);
    update new Lead(
      Id = reproc.Id,
      SOL_Status_Distribuicao__c = 'Erro',
      SOL_Erro_Distribuicao__c = 'falha anterior'
    );

    Test.startTest();
    SOLDistribuicaoService.Resultado rNormal = SOLDistribuicaoService.distribuir(
      new List<Id>{ normal.Id }
    );
    SOLDistribuicaoService.Resultado rReproc = SOLDistribuicaoService.distribuir(
      new List<Id>{ reproc.Id }
    );

    // (c) FALLBACK: com o kill-switch desligado, o Lead vai para a fila.
    Lead fallback = novoLead(PRODUTO_RT);
    update new Lead(Id = fallback.Id, SOL_Status_Distribuicao__c = 'Pendente');
    update new SOL_Distribuicao_Estado__c(
      Id = [SELECT Id FROM SOL_Distribuicao_Estado__c LIMIT 1].Id,
      Ativo__c = false
    );
    SOLDistribuicaoService.Resultado rFallback = SOLDistribuicaoService.distribuir(
      new List<Id>{ fallback.Id }
    );
    Test.stopTest();

    // (a)
    System.assertEquals(1, rNormal.distribuidos, 'Distribuição normal intacta.');
    Lead dNormal = leadDistribuicao(normal.Id);
    System.assertEquals('Distribuido', dNormal.SOL_Status_Distribuicao__c);
    System.assert(new Set<Id>(vs).contains(dNormal.OwnerId), 'Dono é vendedor ativo da fila.');
    System.assertNotEquals(
      null,
      dNormal.SOL_Data_Inicio_Ciclo_Contato__c,
      'O ciclo de contato foi aberto.'
    );
    System.assertEquals(
      ligacoesAntes + 1,
      [SELECT COUNT() FROM Task WHERE WhoId = :normal.Id AND Subject = '1ª Ligação'],
      'A distribuição criou uma nova tarefa de 1ª ligação.'
    );

    // (b)
    System.assertEquals(1, rReproc.distribuidos, 'Reprocessamento intacto.');
    Lead dReproc = leadDistribuicao(reproc.Id);
    System.assertEquals('Distribuido', dReproc.SOL_Status_Distribuicao__c);
    System.assertEquals(null, dReproc.SOL_Erro_Distribuicao__c, 'O erro anterior foi limpo.');
    System.assert(new Set<Id>(vs).contains(dReproc.OwnerId));

    // (c)
    System.assertEquals(1, rFallback.emFallback, 'Fallback intacto.');
    Lead dFallback = leadDistribuicao(fallback.Id);
    System.assertEquals('Fallback', dFallback.SOL_Status_Distribuicao__c);
    System.assertEquals(
      [SELECT Id FROM Group WHERE DeveloperName = :FILA_SINTETICA LIMIT 1].Id,
      dFallback.OwnerId,
      'No fallback o Lead fica na fila.'
    );
  }

  /**
   * A ordem determinística da rotação (CreatedDate ASC, Id ASC) foi preservada
   * ao migrar do `ORDER BY` da consulta para a ordenação em memória — SOQL
   * recusa `ORDER BY` junto de `FOR UPDATE`. Com 3 vendedores e 3 Leads criados
   * em sequência, cada um recebe um vendedor distinto, na ordem de criação.
   */
  @IsTest
  static void ordemDeterministicaDaRotacaoPreservada() {
    List<Id> vs = montarFila(3);
    List<Id> leads = new List<Id>();
    for (Integer i = 0; i < 3; i++) {
      Lead l = novoLead(PRODUTO_RT);
      update new Lead(Id = l.Id, SOL_Status_Distribuicao__c = 'Pendente');
      leads.add(l.Id);
    }

    Test.startTest();
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(leads);
    Test.stopTest();

    System.assertEquals(3, r.distribuidos, 'Os três foram distribuídos.');
    Map<Id, Lead> porId = new Map<Id, Lead>(
      [
        SELECT Id, OwnerId, CreatedDate, SOL_Status_Distribuicao__c
        FROM Lead
        WHERE Id IN :leads
      ]
    );
    Set<Id> donos = new Set<Id>();
    for (Lead l : porId.values()) {
      System.assertEquals('Distribuido', l.SOL_Status_Distribuicao__c);
      donos.add(l.OwnerId);
    }
    System.assertEquals(
      3,
      donos.size(),
      'Round-robin distinto por Lead — a ordenação determinística foi preservada.'
    );
    System.assertEquals(
      new Set<Id>(vs),
      donos,
      'E os três vendedores ativos da fila foram usados exatamente uma vez.'
    );
  }

  // ============================================ 16. BATCH DO 9424

  /** (16) O Batch do prazo total (CLICKUP-9424) ignora Oportunidade fechada. */
  @IsTest
  static void batchDoPrazoTotalIgnoraOportunidadeFechada() {
    List<Id> vs = montarFila(3);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    // Prazo total já vencido, mas o negócio foi perdido.
    update new Opportunity(
      Id = oppId,
      SOL_Data_Inicio_Ciclo_Comercial__c = Datetime.now().addDays(-60),
      SOL_Prazo_Total_Comercial__c = Datetime.now().addDays(-1)
    );
    perderOpp(oppId);
    Id donoAntes = opp(oppId).OwnerId;

    Test.startTest();
    Database.executeBatch(new SOLPrazoTotalBatch(), SOLPrazoTotalScheduler.TAMANHO_LOTE);
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(0, r.reatribuidas, 'Oportunidade perdida não é reatribuída por prazo.');
    System.assertEquals(1, r.ignoradas);
    Opportunity o = opp(oppId);
    System.assertEquals(donoAntes, o.OwnerId, 'Proprietário intacto.');
    System.assertEquals(true, o.IsClosed, '"Perdido" fecha a Oportunidade.');
    System.assert(
      SOLNegocioPerdidoService.oportunidadePerdida(o),
      'E o predicado do card reconhece a perda.'
    );
  }

  // ============================================ PREDICADOS (régua única)

  /** A régua de "negócio perdido" é única e exige o sinal COMPLETO. */
  @IsTest
  static void predicadosExigemOSinalCompleto() {
    // Lead — só é perda com desqualificação + motivo de perda + sem opt-out.
    System.assertEquals(
      true,
      SOLNegocioPerdidoService.leadPerdido(
        new Lead(
          Status = 'Desqualificado',
          SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA,
          SOL_Opt_Out__c = false
        )
      ),
      'Sinal completo: é perda.'
    );
    System.assertEquals(
      false,
      SOLNegocioPerdidoService.leadPerdido(
        new Lead(
          Status = 'Desqualificado',
          SOL_Motivo_Desqualificacao__c = 'Opt-out',
          SOL_Opt_Out__c = true
        )
      ),
      'Opt-out não é perda.'
    );
    System.assertEquals(
      false,
      SOLNegocioPerdidoService.leadPerdido(
        new Lead(Status = 'Desqualificado', SOL_Opt_Out__c = false)
      ),
      'Desqualificado sem motivo não é perda.'
    );
    System.assertEquals(
      false,
      SOLNegocioPerdidoService.leadPerdido(
        new Lead(
          Status = 'Captação - Contato',
          SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA,
          SOL_Opt_Out__c = false
        )
      ),
      'Motivo sem a desqualificação não é perda.'
    );
    System.assertEquals(false, SOLNegocioPerdidoService.leadPerdido(null), 'Nulo não é perda.');

    // Opportunity — só "Perdido".
    System.assertEquals(
      true,
      SOLNegocioPerdidoService.oportunidadePerdida(new Opportunity(StageName = 'Perdido'))
    );
    System.assertEquals(
      false,
      SOLNegocioPerdidoService.oportunidadePerdida(new Opportunity(StageName = 'Ganho')),
      'Ganho NÃO é perda.'
    );
    System.assertEquals(
      false,
      SOLNegocioPerdidoService.oportunidadePerdida(new Opportunity(StageName = 'Negociação'))
    );
    System.assertEquals(false, SOLNegocioPerdidoService.oportunidadePerdida(null));
  }

  /** Entradas inválidas são no-op: nada de exceção, nada gravado. */
  @IsTest
  static void entradasInvalidasSaoNoOp() {
    Test.startTest();
    SOLNegocioPerdidoService.ResultadoPerda r1 = SOLNegocioPerdidoService.encerrarPorLeadPerdido(
      null
    );
    SOLNegocioPerdidoService.ResultadoPerda r2 = SOLNegocioPerdidoService.encerrarPorLeadPerdido(
      new List<Id>()
    );
    // Id de outro tipo na entrada do Lead.
    SOLNegocioPerdidoService.ResultadoPerda r3 = SOLNegocioPerdidoService.encerrarPorLeadPerdido(
      new List<Id>{ UserInfo.getUserId() }
    );
    SOLNegocioPerdidoService.ResultadoPerda r4 = SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
      new List<Id>{ UserInfo.getUserId() }
    );
    Test.stopTest();

    System.assertEquals(0, r1.negociosPerdidos);
    System.assertEquals(0, r2.negociosPerdidos);
    System.assertEquals(0, r3.negociosPerdidos);
    System.assertEquals(0, r4.negociosPerdidos);
  }

  /** Os dois Invocables consolidam os Ids e delegam ao serviço. */
  @IsTest
  static void invocablesDelegamAoServico() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Id t = tarefa(null, oppId, vs[0], 'Contato').Id;
    update new Opportunity(Id = oppId, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');
    update new Task(
      Id = t,
      Status = 'Open',
      SOL_Cancelada_Por_Perda__c = false,
      SOL_Motivo_Cancelamento__c = null
    );

    Lead l = novoLead(PRODUTO_ART);
    Id tl = tarefa(l.Id, null, lead(l.Id).OwnerId, 'Contato').Id;
    perderLead(l.Id);
    update new Task(
      Id = tl,
      Status = 'Open',
      SOL_Cancelada_Por_Perda__c = false,
      SOL_Motivo_Cancelamento__c = null
    );

    Test.startTest();
    SOLNegocioPerdidoOportunidadeInvocable.Entrada eOpp = new SOLNegocioPerdidoOportunidadeInvocable.Entrada();
    eOpp.opportunityId = oppId;
    SOLNegocioPerdidoOportunidadeInvocable.encerrar(
      new List<SOLNegocioPerdidoOportunidadeInvocable.Entrada>{ eOpp }
    );

    SOLNegocioPerdidoLeadInvocable.Entrada eLead = new SOLNegocioPerdidoLeadInvocable.Entrada();
    eLead.leadId = l.Id;
    SOLNegocioPerdidoLeadInvocable.encerrar(
      new List<SOLNegocioPerdidoLeadInvocable.Entrada>{ eLead }
    );

    // Entradas vazias/nulas: no-op silencioso.
    SOLNegocioPerdidoOportunidadeInvocable.encerrar(null);
    SOLNegocioPerdidoLeadInvocable.encerrar(
      new List<SOLNegocioPerdidoLeadInvocable.Entrada>()
    );
    Test.stopTest();

    assertCanceladaPorPerda(t, 'Via Invocable da Oportunidade');
    assertCanceladaPorPerda(tl, 'Via Invocable do Lead');
  }

  /**
   * Os Invocables relançam a exceção controlada do serviço (é o que faz o Flow
   * abortar a perda) e ignoram Ids de outro tipo.
   */
  @IsTest
  static void invocablesRelancamFalhaControladaEFiltramTipo() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Id tOpp = tarefa(null, oppId, vs[0], 'Contato').Id;
    update new Opportunity(Id = oppId, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');
    update new Task(
      Id = tOpp,
      Status = 'Open',
      SOL_Cancelada_Por_Perda__c = false,
      SOL_Motivo_Cancelamento__c = null
    );

    Lead l = novoLead(PRODUTO_ART);
    perderLead(l.Id);
    Task tl = [SELECT Id FROM Task WHERE WhoId = :l.Id LIMIT 1];
    update new Task(
      Id = tl.Id,
      Status = 'Open',
      SOL_Cancelada_Por_Perda__c = false,
      SOL_Motivo_Cancelamento__c = null
    );

    // Id de outro tipo: consolidado fora, sem chamar o serviço.
    SOLNegocioPerdidoOportunidadeInvocable.Entrada eTipoErrado = new SOLNegocioPerdidoOportunidadeInvocable.Entrada();
    eTipoErrado.opportunityId = UserInfo.getUserId();
    SOLNegocioPerdidoLeadInvocable.Entrada eLeadTipoErrado = new SOLNegocioPerdidoLeadInvocable.Entrada();
    eLeadTipoErrado.leadId = UserInfo.getUserId();

    Test.startTest();
    SOLNegocioPerdidoOportunidadeInvocable.encerrar(
      new List<SOLNegocioPerdidoOportunidadeInvocable.Entrada>{ eTipoErrado }
    );
    SOLNegocioPerdidoLeadInvocable.encerrar(
      new List<SOLNegocioPerdidoLeadInvocable.Entrada>{ eLeadTipoErrado }
    );

    Test.setReadOnlyApplicationMode(true);
    Boolean lancouOpp = false;
    try {
      SOLNegocioPerdidoOportunidadeInvocable.Entrada e1 = new SOLNegocioPerdidoOportunidadeInvocable.Entrada();
      e1.opportunityId = oppId;
      SOLNegocioPerdidoOportunidadeInvocable.encerrar(
        new List<SOLNegocioPerdidoOportunidadeInvocable.Entrada>{ e1 }
      );
    } catch (SOLNegocioPerdidoService.NegocioPerdidoException e) {
      lancouOpp = true;
    }
    Boolean lancouLead = false;
    try {
      SOLNegocioPerdidoLeadInvocable.Entrada e2 = new SOLNegocioPerdidoLeadInvocable.Entrada();
      e2.leadId = l.Id;
      SOLNegocioPerdidoLeadInvocable.encerrar(
        new List<SOLNegocioPerdidoLeadInvocable.Entrada>{ e2 }
      );
    } catch (SOLNegocioPerdidoService.NegocioPerdidoException e) {
      lancouLead = true;
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancouOpp, 'O Invocable da Oportunidade RELANÇA a falha controlada.');
    System.assert(lancouLead, 'O Invocable do Lead RELANÇA a falha controlada.');
    System.assertEquals('Open', recarregar(tOpp).Status, 'Nada foi gravado na Opp.');
    System.assertEquals('Open', recarregar(tl.Id).Status, 'Nada foi gravado no Lead.');
  }

  // ============================================ 17. FLS EFETIVA

  /**
   * (17) FLS EFETIVA em System.runAs, com usuários Standard — um por permission
   * set. Vendedor (PS_SOL_Comercial) e gestor (PS_SOL_Distribuicao_Admin)
   * precisam LER os dois campos que distinguem uma Task cancelada por perda de
   * uma Task realizada ou cancelada por outro motivo, e nenhum dos dois pode
   * EDITÁ-LOS: são campos técnicos, escritos só pela automação.
   */
  @IsTest
  static void flsEfetiva_vendedorEGestor() {
    User vCom = vendedor('com' + rnd().left(4));
    User vAdm = vendedor('adm' + rnd().left(4));
    System.runAs(contextoAtual()) {
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

    Test.startTest();
    for (User u : new List<User>{ vCom, vAdm }) {
      String papel = u.Id == vCom.Id ? 'PS_SOL_Comercial' : 'PS_SOL_Distribuicao_Admin';
      System.runAs(new User(Id = u.Id)) {
        for (
          Schema.SObjectField f : new List<Schema.SObjectField>{
            Task.SOL_Cancelada_Por_Perda__c,
            Task.SOL_Motivo_Cancelamento__c
          }
        ) {
          Schema.DescribeFieldResult d = f.getDescribe();
          System.assert(
            d.isAccessible(),
            papel + ': ' + d.getName() + ' é legível — é o que distingue a perda.'
          );
          System.assert(
            !d.isUpdateable(),
            papel + ': ' + d.getName() + ' NÃO é editável (campo técnico).'
          );
        }
      }
    }
    // O tipo da tarefa já era somente leitura para o Comercial (CLICKUP-9417);
    // este card não o alterou.
    System.runAs(vCom) {
      Schema.DescribeFieldResult d = Task.SOL_Tipo_Tarefa__c.getDescribe();
      System.assert(d.isAccessible(), 'Comercial: SOL_Tipo_Tarefa__c é legível.');
      System.assert(!d.isUpdateable(), 'Comercial: SOL_Tipo_Tarefa__c NÃO é editável.');
    }
    Test.stopTest();
  }

  /**
   * Verificação ESTRUTURAL: os dois campos que distinguem a perda têm FLS
   * declarada — legível e não editável — nos DOIS permission sets.
   */
  @IsTest
  static void flsDeclaradaNosDoisPermissionSets() {
    Set<String> campos = new Set<String>{
      'Task.SOL_Cancelada_Por_Perda__c',
      'Task.SOL_Motivo_Cancelamento__c'
    };
    for (String ps : new List<String>{ 'PS_SOL_Comercial', 'PS_SOL_Distribuicao_Admin' }) {
      Set<String> vistos = new Set<String>();
      for (FieldPermissions fp : [
        SELECT Field, PermissionsRead, PermissionsEdit
        FROM FieldPermissions
        WHERE Parent.Name = :ps AND SobjectType = 'Task' AND Field IN :campos
      ]) {
        vistos.add(fp.Field);
        System.assert(fp.PermissionsRead, ps + ' — ' + fp.Field + ': legível.');
        System.assertEquals(
          false,
          fp.PermissionsEdit,
          ps + ' — ' + fp.Field + ': somente leitura.'
        );
      }
      System.assertEquals(
        campos,
        vistos,
        ps + ' declara FLS dos dois campos que distinguem a perda.'
      );
    }
  }

  // ============================== 18. HISTÓRICO E ACESSO (honestamente)

  /**
   * (18) O que este card ENTREGA e o que DEPENDE da configuração da org —
   * separando FLS de compartilhamento/perfil, sem exagerar o escopo.
   *
   * ENTREGUE: o histórico do cancelamento fica no PRÓPRIO registro da Task
   * (Status "Cancelada" + motivo + flag), preservado e distinguível de uma
   * tarefa executada — nada é apagado. Mais a FLS de leitura dos campos
   * técnicos para os dois papéis (ver flsEfetiva_vendedorEGestor).
   *
   * NÃO ENTREGUE por este card: a visibilidade de REGISTRO da Task para quem
   * não é dono. `PS_SOL_Comercial` não concede `objectPermissions` de Task —
   * este teste ASSERE essa ausência para registrar a dependência em código. Quem
   * vê a tarefa de outro vendedor a vê pelo perfil/hierarquia já configurados na
   * org. A medição com usuários REAIS está no E2E
   * (`scripts/apex/clickup-9425-evidencia-perda.apex`, via `UserRecordAccess`).
   */
  @IsTest
  static void historicoNoRegistroEDependenciaDeCompartilhamento() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Id t = tarefa(null, oppId, vs[0], 'Contato').Id;

    Test.startTest();
    perderOpp(oppId);
    Test.stopTest();

    // ENTREGUE — o histórico do encerramento está no próprio registro.
    Task depois = recarregar(t);
    System.assertEquals('Cancelada', depois.Status, 'O registro guarda o encerramento.');
    System.assertEquals(MOTIVO_PERDA, depois.SOL_Motivo_Cancelamento__c);
    System.assertEquals(true, depois.SOL_Cancelada_Por_Perda__c);
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE Id = :t],
      'A Task NÃO foi apagada — o histórico é preservado.'
    );

    // ENTREGUE — o dono tem acesso de registro, confirmado pelo runtime.
    System.runAs(new User(Id = vs[0])) {
      List<UserRecordAccess> acesso = [
        SELECT RecordId, HasReadAccess
        FROM UserRecordAccess
        WHERE UserId = :vs[0] AND RecordId = :t
      ];
      System.assertEquals(1, acesso.size(), 'UserRecordAccess respondeu para o dono da tarefa.');
      System.assertEquals(true, acesso[0].HasReadAccess, 'O dono lê a própria tarefa.');
    }

    // DEPENDÊNCIA registrada: o PS do Comercial não concede o objeto Task.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM ObjectPermissions
        WHERE Parent.Name = 'PS_SOL_Comercial' AND SobjectType = 'Task'
      ],
      'PS_SOL_Comercial não concede objeto Task: a visibilidade de registro vem ' +
        'de perfil/hierarquia da org, não deste card.'
    );
  }

  // ============================================ REGRESSÃO DA VR

  /**
   * A VR SOL_Cancelada_Exige_Classificacao mantém a proteção para qualquer
   * cancelamento que não seja por perda — e a exceção vale SÓ para o tipo.
   */
  @IsTest
  static void vrDeCancelamentoMantemProtecaoForaDaPerda() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');

    Test.startTest();
    // (a) Cancelada sem tipo E sem a flag de perda: BLOQUEADO.
    Task semTipoSemFlag = tarefa(null, oppId, vs[0], null);
    Boolean bloqueouSemFlag = false;
    try {
      update new Task(
        Id = semTipoSemFlag.Id,
        Status = 'Cancelada',
        SOL_Motivo_Cancelamento__c = MOTIVO_PERDA
      );
    } catch (DmlException e) {
      bloqueouSemFlag = true;
    }

    // (b) Cancelada com a flag mas SEM motivo: BLOQUEADO (motivo é obrigatório).
    Task semMotivo = tarefa(null, oppId, vs[0], null);
    Boolean bloqueouSemMotivo = false;
    try {
      update new Task(
        Id = semMotivo.Id,
        Status = 'Cancelada',
        SOL_Cancelada_Por_Perda__c = true
      );
    } catch (DmlException e) {
      bloqueouSemMotivo = true;
    }

    // (c) Cancelada com tipo e motivo, sem flag: PERMITIDO (regra original).
    Task tipada = tarefa(null, oppId, vs[0], 'Contato');
    update new Task(
      Id = tipada.Id,
      Status = 'Cancelada',
      SOL_Motivo_Cancelamento__c = 'Contato efetivado'
    );

    // (d) Sem tipo, com flag E motivo de perda: PERMITIDO (a exceção do card).
    Task manualPorPerda = tarefa(null, oppId, vs[0], null);
    update new Task(
      Id = manualPorPerda.Id,
      Status = 'Cancelada',
      SOL_Motivo_Cancelamento__c = MOTIVO_PERDA,
      SOL_Cancelada_Por_Perda__c = true
    );
    Test.stopTest();

    System.assert(bloqueouSemFlag, 'Sem tipo e sem flag de perda: segue bloqueado.');
    System.assert(bloqueouSemMotivo, 'O motivo continua obrigatório em todo cancelamento.');
    System.assertEquals('Cancelada', recarregar(tipada.Id).Status, 'Regra original preservada.');
    System.assertEquals(
      'Cancelada',
      recarregar(manualPorPerda.Id).Status,
      'A exceção do card permite tarefa manual sem tipo.'
    );
  }

  // ============================== 18. D2 — PERDA MANUAL PELO VENDEDOR
  //
  // A homologação E2E mostrou que SOL_Motivo_Desqualificacao__c era somente
  // leitura em TODOS os permission sets da org: nenhum vendedor conseguia
  // marcar "Negócio perdido", e a entrada do card pelo Lead era inalcançável.
  // O campo agora é editável no PS_SOL_Comercial, e a VR
  // SOL_Desqualificacao_Coerente garante que motivo e flag de opt-out não
  // possam divergir.

  /** Vendedor Standard com um único permission set: o PS_SOL_Comercial. */
  private static User vendedorComPsComercial(String tag) {
    User u = vendedor(tag);
    System.runAs(contextoAtual()) {
      insert u;
      insert new PermissionSetAssignment(
        AssigneeId = u.Id,
        PermissionSetId = [
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'PS_SOL_Comercial'
          LIMIT 1
        ]
        .Id
      );
    }
    return u;
  }

  /**
   * (18.1) O vendedor perde o negócio pela edição que agora lhe é permitida —
   * em USER_MODE, que é o que o botão de salvar da tela faz: valida FLS e CRUD
   * do usuário, não só a VR.
   */
  @IsTest
  static void vendedorPerdeLeadPelaEdicaoPermitida() {
    User vend = vendedorComPsComercial('d2a' + rnd().left(3));
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(Id = l.Id, OwnerId = vend.Id);

    Test.startTest();
    System.runAs(new User(Id = vend.Id)) {
      // Não toca em SOL_Opt_Out__c: continua somente leitura para o vendedor.
      Database.update(
        new List<Lead>{
          new Lead(
            Id = l.Id,
            Status = 'Desqualificado',
            SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA
          )
        },
        AccessLevel.USER_MODE
      );
    }
    Test.stopTest();

    Lead depois = lead(l.Id);
    System.assertEquals('Desqualificado', depois.Status, 'Lead desqualificado.');
    System.assertEquals(
      MOTIVO_PERDA,
      depois.SOL_Motivo_Desqualificacao__c,
      'O vendedor conseguiu gravar o motivo da perda.'
    );
    System.assert(
      depois.SOL_Opt_Out__c != true,
      'Perda comercial não é opt-out.'
    );
    System.assert(
      SOLNegocioPerdidoService.leadPerdido(depois),
      'O sinal de perda do card ficou completo.'
    );
  }

  /**
   * (18.2) A perda feita pelo vendedor dispara o encerramento do 9425: as
   * tarefas abertas do Lead são canceladas pelo Flow, inclusive a manual sem
   * tipo, e as já concluídas ficam intactas.
   */
  @IsTest
  static void perdaManualDoVendedorCancelaAsTarefasAbertas() {
    User vend = vendedorComPsComercial('d2b' + rnd().left(3));
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(Id = l.Id, OwnerId = vend.Id);

    Task aberta = tarefa(l.Id, null, vend.Id, 'Contato');
    Task manual = tarefa(l.Id, null, vend.Id, null);
    Task concluida = tarefa(l.Id, null, vend.Id, 'Contato');
    update new Task(
      Id = concluida.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Não atendeu'
    );

    Test.startTest();
    System.runAs(new User(Id = vend.Id)) {
      Database.update(
        new List<Lead>{
          new Lead(
            Id = l.Id,
            Status = 'Desqualificado',
            SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA
          )
        },
        AccessLevel.USER_MODE
      );
    }
    Test.stopTest();

    assertCanceladaPorPerda(aberta.Id, 'tarefa tipada aberta');
    assertCanceladaPorPerda(manual.Id, 'tarefa manual sem tipo');
    Task jaFeita = recarregar(concluida.Id);
    System.assertEquals(
      'Completed',
      jaFeita.Status,
      'Tarefa já concluída não é reescrita pela perda.'
    );
    System.assert(
      jaFeita.SOL_Cancelada_Por_Perda__c != true,
      'Tarefa concluída não recebe a marca de cancelamento por perda.'
    );
  }

  /**
   * (18.3) O opt-out automático continua funcionando depois da mudança de FLS
   * e da nova VR: quem grava motivo e flag juntos é a automação, e o resultado
   * NÃO é lido como "Negócio perdido".
   */
  @IsTest
  static void optOutAutomaticoSegueFuncionandoComANovaRegra() {
    List<Id> vs = montarFila(2);
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(Id = l.Id, OwnerId = vs[0]);
    Task contato = tarefa(l.Id, null, vs[0], 'Contato');
    Task outra = tarefa(l.Id, null, vs[0], 'Contato');

    Test.startTest();
    update new Task(
      Id = contato.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Opt-out'
    );
    Test.stopTest();

    Lead depois = lead(l.Id);
    System.assertEquals('Desqualificado', depois.Status, 'Opt-out desqualifica.');
    System.assertEquals(true, depois.SOL_Opt_Out__c, 'Flag de opt-out ligada.');
    System.assertEquals(
      'Opt-out',
      depois.SOL_Motivo_Desqualificacao__c,
      'Motivo gravado pela automação.'
    );
    System.assertNotEquals(
      null,
      depois.SOL_Data_Opt_Out__c,
      'Data do opt-out registrada.'
    );
    System.assert(
      !SOLNegocioPerdidoService.leadPerdido(depois),
      'Opt-out NÃO é negócio perdido.'
    );
    Task cancelada = recarregar(outra.Id);
    System.assertEquals(
      'Cancelada',
      cancelada.Status,
      'Tarefa de contato cancelada pelo opt-out.'
    );
    System.assertEquals(
      'Opt-out',
      cancelada.SOL_Motivo_Cancelamento__c,
      'Cancelada por opt-out, não por perda.'
    );
    System.assert(
      cancelada.SOL_Cancelada_Por_Perda__c != true,
      'A marca de perda não contamina o opt-out.'
    );
  }

  /**
   * (18.4) Combinações incoerentes são bloqueadas pela VR — inclusive quando
   * quem grava é administrador por Apex, que é o caminho da API. Cobre os cinco
   * casos exigidos.
   */
  @IsTest
  static void combinacoesIncoerentesDeDesqualificacaoSaoBloqueadas() {
    Lead a = novoLead(PRODUTO_RT);
    Lead b = novoLead(PRODUTO_RT);
    Lead c = novoLead(PRODUTO_RT);
    Lead d = novoLead(PRODUTO_ART);

    Test.startTest();
    // (i) Desqualificado + "Opt-out" sem a flag ligada.
    Boolean bloqueouOptOutSemFlag = false;
    try {
      update new Lead(
        Id = a.Id,
        Status = 'Desqualificado',
        SOL_Motivo_Desqualificacao__c = 'Opt-out'
      );
    } catch (DmlException e) {
      bloqueouOptOutSemFlag = true;
    }

    // (ii) Desqualificado + "Negócio perdido" com a flag de opt-out ligada.
    Boolean bloqueouPerdaComFlag = false;
    try {
      update new Lead(
        Id = b.Id,
        Status = 'Desqualificado',
        SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA,
        SOL_Opt_Out__c = true
      );
    } catch (DmlException e) {
      bloqueouPerdaComFlag = true;
    }

    // (iii) Desqualificado sem motivo nenhum.
    Boolean bloqueouSemMotivo = false;
    try {
      update new Lead(Id = c.Id, Status = 'Desqualificado');
    } catch (DmlException e) {
      bloqueouSemMotivo = true;
    }

    // (iv) Flag de opt-out ligada com outro motivo, sem desqualificar.
    Boolean bloqueouFlagComOutroMotivo = false;
    try {
      update new Lead(
        Id = d.Id,
        SOL_Opt_Out__c = true,
        SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA
      );
    } catch (DmlException e) {
      bloqueouFlagComOutroMotivo = true;
    }

    // (v) Flag de opt-out ligada sem motivo algum.
    Boolean bloqueouFlagSemMotivo = false;
    try {
      update new Lead(Id = d.Id, SOL_Opt_Out__c = true);
    } catch (DmlException e) {
      bloqueouFlagSemMotivo = true;
    }
    Test.stopTest();

    System.assert(bloqueouOptOutSemFlag, '(i) Motivo "Opt-out" exige a flag ligada.');
    System.assert(bloqueouPerdaComFlag, '(ii) "Negócio perdido" exige a flag desligada.');
    System.assert(bloqueouSemMotivo, '(iii) Desqualificar exige um motivo válido.');
    System.assert(
      bloqueouFlagComOutroMotivo,
      '(iv) Flag de opt-out com outro motivo é incoerente.'
    );
    System.assert(bloqueouFlagSemMotivo, '(v) Flag de opt-out sem motivo é incoerente.');

    // Nenhum dos leads ficou num estado incoerente.
    for (Lead l : [
      SELECT Status, SOL_Motivo_Desqualificacao__c, SOL_Opt_Out__c
      FROM Lead
      WHERE Id IN (:a.Id, :b.Id, :c.Id, :d.Id)
    ]) {
      System.assert(
        l.Status != 'Desqualificado',
        'Nenhuma das gravações incoerentes passou.'
      );
      System.assert(l.SOL_Opt_Out__c != true, 'A flag não foi ligada à força.');
    }
  }

  /**
   * (18.5) A VR é do Record Type SOL. Leads de outras unidades continuam
   * podendo ser desqualificados sem os campos da jornada SOL.
   */
  @IsTest
  static void novaRegraNaoAfetaOutrosRecordTypes() {
    Lead fora = new Lead(
      LastName = 'Fora SOL ' + rnd(),
      Company = 'Outra BU ' + rnd(),
      Status = 'Captação - Contato'
    );
    insert fora;

    Test.startTest();
    update new Lead(Id = fora.Id, Status = 'Desqualificado');
    Test.stopTest();

    Lead depois = [
      SELECT Status, RecordTypeId, SOL_Motivo_Desqualificacao__c
      FROM Lead
      WHERE Id = :fora.Id
    ];
    System.assertEquals(
      'Desqualificado',
      depois.Status,
      'Fora do Record Type SOL a regra não se aplica.'
    );
    System.assertNotEquals(
      rtLeadSOL(),
      depois.RecordTypeId,
      'O lead do cenário não é do Record Type SOL.'
    );
  }

  /**
   * (18.6) FLS efetiva do motivo depois da correção: o VENDEDOR edita, o GESTOR
   * só lê. E os campos de opt-out seguem somente leitura para os dois — quem os
   * grava é a automação.
   */
  @IsTest
  static void flsDoMotivoVendedorEditaGestorSoLe() {
    User vCom = vendedor('d2c' + rnd().left(3));
    User vAdm = vendedor('d2g' + rnd().left(3));
    System.runAs(contextoAtual()) {
      insert new List<User>{ vCom, vAdm };
      insert new List<PermissionSetAssignment>{
        new PermissionSetAssignment(
          AssigneeId = vCom.Id,
          PermissionSetId = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = 'PS_SOL_Comercial'
            LIMIT 1
          ]
          .Id
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

    Test.startTest();
    System.runAs(new User(Id = vCom.Id)) {
      Schema.DescribeFieldResult motivo = Lead.SOL_Motivo_Desqualificacao__c.getDescribe();
      System.assert(motivo.isAccessible(), 'Vendedor lê o motivo.');
      System.assert(
        motivo.isUpdateable(),
        'Vendedor EDITA o motivo — é a correção do D2.'
      );
      System.assert(
        !Lead.SOL_Opt_Out__c.getDescribe().isUpdateable(),
        'Vendedor não edita a flag de opt-out.'
      );
      System.assert(
        !Lead.SOL_Data_Opt_Out__c.getDescribe().isUpdateable(),
        'Vendedor não edita a data do opt-out.'
      );
    }
    System.runAs(new User(Id = vAdm.Id)) {
      Schema.DescribeFieldResult motivo = Lead.SOL_Motivo_Desqualificacao__c.getDescribe();
      System.assert(motivo.isAccessible(), 'Gestor lê o motivo.');
      System.assert(
        !motivo.isUpdateable(),
        'Gestor só lê: quem executa a perda é o vendedor.'
      );
    }
    Test.stopTest();
  }

  /** (18.7) O permission set do gestor não passou a conceder edição do motivo. */
  @IsTest
  static void psDoGestorSegueSemEdicaoDoMotivo() {
    List<FieldPermissions> fp = [
      SELECT PermissionsRead, PermissionsEdit
      FROM FieldPermissions
      WHERE
        Field = 'Lead.SOL_Motivo_Desqualificacao__c'
        AND Parent.Name = 'PS_SOL_Distribuicao_Admin'
    ];
    System.assertEquals(1, fp.size(), 'O gestor declara o campo.');
    System.assert(fp[0].PermissionsRead, 'Gestor lê.');
    System.assert(!fp[0].PermissionsEdit, 'Gestor não edita.');

    List<FieldPermissions> vend = [
      SELECT PermissionsRead, PermissionsEdit
      FROM FieldPermissions
      WHERE
        Field = 'Lead.SOL_Motivo_Desqualificacao__c'
        AND Parent.Name = 'PS_SOL_Comercial'
    ];
    System.assertEquals(1, vend.size(), 'O vendedor declara o campo.');
    System.assert(vend[0].PermissionsRead && vend[0].PermissionsEdit, 'Vendedor lê e edita.');
  }

  // ============================== 19. D3 — CANCELAMENTO DA TASK DE FECHAMENTO
  //
  // A homologação E2E conseguiu cancelar à mão uma tarefa de Fechamento com
  // motivo "Contato efetivado", contornando a garantia de encerramento
  // automático. A VR SOL_Fechamento_Exige_Encerramento_Auto passou a cobrir o
  // cancelamento além da conclusão.

  /** Tarefa de Fechamento aberta, pendurada numa Oportunidade SOL. */
  private static Task tarefaDeFechamento(Id oppId, Id owner) {
    return tarefa(null, oppId, owner, 'Fechamento');
  }

  /**
   * (19.1) Cancelamento manual em UPDATE: bloqueado em todas as combinações que
   * não sejam o sinal completo de perda — inclusive o caso exato observado na
   * homologação (Fechamento + Cancelada + "Contato efetivado").
   */
  @IsTest
  static void fechamentoNaoCancelaSemOSinalDePerda_update() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');

    Task caso1 = tarefaDeFechamento(oppId, vs[0]);
    Task caso2 = tarefaDeFechamento(oppId, vs[0]);
    Task caso3 = tarefaDeFechamento(oppId, vs[0]);

    Test.startTest();
    // (a) o desvio da homologação: motivo de outro fluxo, sem flag.
    Boolean bloqueouContatoEfetivado = false;
    try {
      update new Task(
        Id = caso1.Id,
        Status = 'Cancelada',
        SOL_Motivo_Cancelamento__c = 'Contato efetivado'
      );
    } catch (DmlException e) {
      bloqueouContatoEfetivado = true;
    }

    // (b) motivo certo, flag ausente.
    Boolean bloqueouSemFlag = false;
    try {
      update new Task(
        Id = caso2.Id,
        Status = 'Cancelada',
        SOL_Motivo_Cancelamento__c = MOTIVO_PERDA
      );
    } catch (DmlException e) {
      bloqueouSemFlag = true;
    }

    // (c) flag certa, motivo de outro fluxo.
    Boolean bloqueouFlagComOutroMotivo = false;
    try {
      update new Task(
        Id = caso3.Id,
        Status = 'Cancelada',
        SOL_Cancelada_Por_Perda__c = true,
        SOL_Motivo_Cancelamento__c = 'Contato efetivado'
      );
    } catch (DmlException e) {
      bloqueouFlagComOutroMotivo = true;
    }
    Test.stopTest();

    System.assert(
      bloqueouContatoEfetivado,
      'Fechamento + Cancelada + "Contato efetivado" tem de ser bloqueado.'
    );
    System.assert(bloqueouSemFlag, 'Sem a flag de perda o cancelamento é manual.');
    System.assert(
      bloqueouFlagComOutroMotivo,
      'A flag sozinha não autoriza: o motivo tem de ser "Negócio perdido".'
    );
    for (Id t : new List<Id>{ caso1.Id, caso2.Id, caso3.Id }) {
      System.assertEquals(
        'Open',
        recarregar(t).Status,
        'Nenhuma das tentativas manuais encerrou a tarefa.'
      );
    }
  }

  /** (19.2) O mesmo bloqueio no INSERT — nascer cancelada também é desvio. */
  @IsTest
  static void fechamentoNaoNasceCanceladoSemOSinalDePerda_insert() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');

    Test.startTest();
    Boolean bloqueou = false;
    try {
      insert new Task(
        Subject = 'T ' + rnd(),
        WhatId = oppId,
        OwnerId = vs[0],
        Status = 'Cancelada',
        ActivityDate = Date.today(),
        SOL_Tipo_Tarefa__c = 'Fechamento',
        SOL_Motivo_Cancelamento__c = 'Contato efetivado'
      );
    } catch (DmlException e) {
      bloqueou = true;
    }
    Test.stopTest();

    System.assert(bloqueou, 'Fechamento não pode nascer cancelado à mão.');
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Task
        WHERE WhatId = :oppId AND SOL_Tipo_Tarefa__c = 'Fechamento'
      ],
      'Nenhuma tarefa de fechamento foi criada.'
    );
  }

  /**
   * (19.3) Com o sinal completo de perda, o cancelamento é permitido — é assim
   * que o 9425 encerra a tarefa de fechamento. Vale em insert e em update.
   */
  @IsTest
  static void fechamentoCancelaComOSinalCompletoDePerda() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Task porUpdate = tarefaDeFechamento(oppId, vs[0]);

    Test.startTest();
    update new Task(
      Id = porUpdate.Id,
      Status = 'Cancelada',
      SOL_Cancelada_Por_Perda__c = true,
      SOL_Motivo_Cancelamento__c = MOTIVO_PERDA
    );
    Task porInsert = new Task(
      Subject = 'T ' + rnd(),
      WhatId = oppId,
      OwnerId = vs[0],
      Status = 'Cancelada',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Fechamento',
      SOL_Cancelada_Por_Perda__c = true,
      SOL_Motivo_Cancelamento__c = MOTIVO_PERDA
    );
    insert porInsert;
    Test.stopTest();

    assertCanceladaPorPerda(porUpdate.Id, 'fechamento cancelado por update');
    assertCanceladaPorPerda(porInsert.Id, 'fechamento cancelado por insert');
  }

  /**
   * (19.4) A regra reforçada não atrapalha o caminho de verdade: a Oportunidade
   * indo para "Perdido" cancela a tarefa de fechamento pelo Flow do 9425.
   */
  @IsTest
  static void oportunidadePerdidaAindaCancelaOFechamento() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Task fechamento = tarefaDeFechamento(oppId, vs[0]);

    Test.startTest();
    perderOpp(oppId);
    Test.stopTest();

    assertCanceladaPorPerda(fechamento.Id, 'fechamento encerrado pela perda da Opp');
    System.assertEquals(
      'Perdido',
      opp(oppId).StageName,
      'A Oportunidade ficou perdida.'
    );
  }

  /**
   * (19.5) Manutenção posterior de registro histórico válido: numa tarefa de
   * fechamento já cancelada pela perda, editar outro campo não reabre a regra.
   */
  @IsTest
  static void manutencaoDeFechamentoJaCanceladoContinuaPermitida() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Task fechamento = tarefaDeFechamento(oppId, vs[0]);
    update new Task(
      Id = fechamento.Id,
      Status = 'Cancelada',
      SOL_Cancelada_Por_Perda__c = true,
      SOL_Motivo_Cancelamento__c = MOTIVO_PERDA
    );

    Test.startTest();
    update new Task(Id = fechamento.Id, Description = 'Anotação posterior do gestor.');
    Test.stopTest();

    Task depois = recarregar(fechamento.Id);
    System.assertEquals(
      'Cancelada',
      depois.Status,
      'O status histórico foi preservado.'
    );
    System.assertEquals(
      'Anotação posterior do gestor.',
      [SELECT Description FROM Task WHERE Id = :fechamento.Id].Description,
      'A manutenção do registro histórico continua possível.'
    );
  }

  /**
   * (19.6) A conclusão pela automação de Ganho (9423) segue funcionando, e a
   * conclusão manual segue bloqueada — a regra ganhou um caso, não trocou de
   * comportamento.
   */
  @IsTest
  static void ganhoAindaConcluiOFechamentoEManualSegueBloqueado() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], 'Negociação');
    Task fechamento = tarefaDeFechamento(oppId, vs[0]);

    Test.startTest();
    Boolean bloqueouManual = false;
    try {
      update new Task(Id = fechamento.Id, Status = 'Completed');
    } catch (DmlException e) {
      bloqueouManual = true;
    }
    update new Task(Id = fechamento.Id, SOL_Encerrado_Pela_Oportunidade__c = true, Status = 'Completed');
    Test.stopTest();

    System.assert(bloqueouManual, 'Conclusão manual do fechamento segue bloqueada.');
    Task depois = recarregar(fechamento.Id);
    System.assertEquals('Completed', depois.Status, 'A automação conclui.');
    System.assert(
      depois.SOL_Cancelada_Por_Perda__c != true,
      'Concluir por Ganho não marca cancelamento por perda.'
    );
  }
}

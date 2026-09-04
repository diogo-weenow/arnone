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

    // (a) Desqualificado SEM motivo nenhum.
    Lead semMotivo = novoLead(PRODUTO_RT);
    Id tSemMotivo = tarefa(semMotivo.Id, null, lead(semMotivo.Id).OwnerId, 'Contato').Id;
    // (b) Desqualificado com motivo de perda MAS com opt-out marcado.
    Lead comOptOut = novoLead(PRODUTO_RT);
    Id tComOptOut = tarefa(comOptOut.Id, null, lead(comOptOut.Id).OwnerId, 'Contato').Id;

    Test.startTest();
    update new Lead(Id = semMotivo.Id, Status = 'Desqualificado');
    update new Lead(
      Id = comOptOut.Id,
      Status = 'Desqualificado',
      SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA,
      SOL_Opt_Out__c = true
    );
    SOLNegocioPerdidoService.ResultadoPerda r = SOLNegocioPerdidoService.encerrarPorLeadPerdido(
      new List<Id>{ semMotivo.Id, comOptOut.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.negociosPerdidos, 'Nenhum dos dois tem o sinal EXATO de perda.');
    System.assertEquals(2, r.ignorados);
    System.assertEquals('Open', recarregar(tSemMotivo).Status, 'Sem motivo: tarefa intacta.');
    System.assertEquals('Open', recarregar(tComOptOut).Status, 'Com opt-out: tarefa intacta.');
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

    // (c) Desqualificado sem o motivo de perda: também BLOQUEADO.
    Boolean bloqueouSemMotivo = false;
    try {
      update new Lead(Id = paraBloquear.Id, Status = 'Desqualificado');
    } catch (DmlException e) {
      bloqueouSemMotivo = e.getMessage().containsIgnoreCase('compromisso');
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
}

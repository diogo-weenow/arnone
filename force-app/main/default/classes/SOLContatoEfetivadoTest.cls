/**
 * CLICKUP-9417 — Testes do cancelamento automático de tarefas de contato
 * pendentes por contato efetivado.
 *
 * O Flow SOL_Contato_Efetivado está ATIVO: concluir uma tarefa de contato SOL
 * (SOL_Tipo_Tarefa__c = 'Contato') com resultado "Atendeu" já dispara a
 * sinalização + cancelamento. Os testes convivem com a automação real e também
 * chamam o serviço diretamente — a operação é idempotente.
 *
 * Nenhum teste depende de permission set: o serviço roda em contexto de sistema.
 */
@IsTest
private class SOLContatoEfetivadoTest {
  private static final String FILA_SINTETICA = 'RR_ContEf_SOL_9417';
  private static final String CNPJ = '11222333000181';

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ---------------------------------------------------------------- helpers

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
  }

  private static User vendedor(Integer i) {
    return new User(
      FirstName = 'RR',
      LastName = 'CEfVend ' + i,
      Alias = ('rce' + i).left(8),
      Email = 'rr.ce' + i + '@arnone.invalid',
      Username = 'rr.ce' +
        i +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9417.test.invalid',
      ProfileId = UserInfo.getProfileId(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private class Cenario {
    Id filaId;
    List<Id> vendedores = new List<Id>();
  }

  private static Cenario montarCenario(Integer qtdVendedores) {
    Cenario c = new Cenario();
    List<User> vs = new List<User>();
    for (Integer i = 0; i < qtdVendedores; i++) {
      vs.add(vendedor(i));
    }
    System.runAs(contextoAtual()) {
      if (!vs.isEmpty()) {
        insert vs;
      }
      Group fila = new Group(
        Name = 'RR ContEf SOL 9417',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      c.filaId = fila.Id;
      List<GroupMember> gms = new List<GroupMember>();
      for (User v : vs) {
        gms.add(new GroupMember(GroupId = fila.Id, UserOrGroupId = v.Id));
      }
      if (!gms.isEmpty()) {
        insert gms;
      }
    }
    for (User v : vs) {
      c.vendedores.add(v.Id);
    }
    c.vendedores.sort();
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
    return c;
  }

  private static Id rtSOL() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static String statusCache;
  private static String statusLead() {
    if (statusCache == null) {
      List<LeadStatus> p = [
        SELECT MasterLabel
        FROM LeadStatus
        WHERE IsDefault = TRUE
        LIMIT 1
      ];
      statusCache = p.isEmpty()
        ? [SELECT MasterLabel FROM LeadStatus LIMIT 1].MasterLabel
        : p[0].MasterLabel;
    }
    return statusCache;
  }

  /** Lead SOL distribuído (Flow cria a 1ª Ligação, tipo Contato, aberta). */
  private static Lead novoLeadSOLDistribuido(String nome, String produto) {
    Lead l = new Lead(
      RecordTypeId = rtSOL(),
      LastName = nome,
      Company = 'C',
      Status = statusLead(),
      CNPJ__c = CNPJ,
      SOL_Produto_Interesse__c = produto
    );
    insert l;
    return recarregar(l.Id);
  }

  private static Lead recarregar(Id id) {
    return [
      SELECT
        Id,
        OwnerId,
        IsConverted,
        SOL_Contato_Efetivado__c,
        SOL_Data_Contato_Efetivado__c,
        SOL_Quantidade_Reatribuicoes__c
      FROM Lead
      WHERE Id = :id
    ];
  }

  /** Insere uma tarefa de contato SOL aberta (como a automação faz). */
  private static Task tarefaContatoAberta(Id leadId, Id owner) {
    Task t = new Task(
      Subject = 'Tentativa de contato',
      WhoId = leadId,
      OwnerId = owner,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Prazo_Contato__c = System.now().addMinutes(5),
      SOL_Tipo_Tarefa__c = 'Contato'
    );
    insert t;
    return t;
  }

  /** Conclui uma tarefa com resultado "Atendeu" (contato efetivado). */
  private static void concluirComoAtendeu(Id taskId) {
    update new Task(
      Id = taskId,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Atendeu'
    );
  }

  private static List<Task> tarefasContato(Id leadId) {
    return [
      SELECT Id, Status, IsClosed, SOL_Resultado_Contato__c, SOL_Motivo_Cancelamento__c
      FROM Task
      WHERE WhoId = :leadId AND SOL_Tipo_Tarefa__c = 'Contato'
      ORDER BY CreatedDate
    ];
  }

  private static Integer abertasDe(Id leadId) {
    return [
      SELECT COUNT()
      FROM Task
      WHERE WhoId = :leadId AND SOL_Tipo_Tarefa__c = 'Contato' AND IsClosed = false
    ];
  }

  // ============================================================ POSITIVO

  @IsTest
  static void contatoEfetivadoCancelaPendentesESinalizaLead() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S1', 'Recuperação Tributária');
    // 1ª Ligação da distribuição + 2 tarefas de contato adicionais abertas.
    tarefaContatoAberta(l.Id, l.OwnerId);
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);
    System.assertEquals(3, abertasDe(l.Id), 'Três tarefas de contato abertas.');

    Test.startTest();
    concluirComoAtendeu(alvo.Id);
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(true, d.SOL_Contato_Efetivado__c, 'Lead sinalizado.');
    System.assertNotEquals(null, d.SOL_Data_Contato_Efetivado__c, 'Data registrada.');
    System.assertEquals(0, abertasDe(l.Id), 'Nenhuma tarefa de contato pendente.');

    for (Task t : tarefasContato(l.Id)) {
      if (t.Id == alvo.Id) {
        System.assertEquals('Completed', t.Status, 'A tarefa do contato fica concluída.');
      } else {
        System.assertEquals('Cancelada', t.Status, 'Pendentes viram Cancelada.');
        System.assertEquals(
          'Contato efetivado',
          t.SOL_Motivo_Cancelamento__c,
          'Motivo do cancelamento registrado.'
        );
      }
    }
  }

  @IsTest
  static void tarefasJaConcluidasNaoSaoAlteradas() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S2', 'Recuperação Tributária');

    // Uma tarefa de contato JÁ concluída (negativa) — histórico anterior.
    Task antiga = tarefaContatoAberta(l.Id, l.OwnerId);
    update new Task(
      Id = antiga.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Não atendeu'
    );

    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    concluirComoAtendeu(alvo.Id);
    Test.stopTest();

    Task antigaRel = [
      SELECT Status, SOL_Resultado_Contato__c, SOL_Motivo_Cancelamento__c
      FROM Task
      WHERE Id = :antiga.Id
    ];
    System.assertEquals('Completed', antigaRel.Status, 'Concluída anterior intacta.');
    System.assertEquals('Não atendeu', antigaRel.SOL_Resultado_Contato__c);
    System.assertEquals(null, antigaRel.SOL_Motivo_Cancelamento__c, 'Não foi cancelada.');
  }

  // ============================================================ NEGATIVO

  @IsTest
  static void resultadoNaoAtendeuNaoSinalizaNemCancela() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S3', 'Recuperação Tributária');
    Task outra = tarefaContatoAberta(l.Id, l.OwnerId);
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    update new Task(
      Id = alvo.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Não atendeu'
    );
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(false, d.SOL_Contato_Efetivado__c, 'Não sinaliza sem "Atendeu".');
    System.assertEquals(
      'Open',
      [SELECT Status FROM Task WHERE Id = :outra.Id].Status,
      'Nenhuma tarefa cancelada.'
    );
  }

  @IsTest
  static void semTipoContatoNaoDisparaAAutomacao() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S4', 'Recuperação Tributária');

    Task manual = new Task(
      Subject = 'Ligação avulsa',
      WhoId = l.Id,
      OwnerId = l.OwnerId,
      Status = 'Completed',
      ActivityDate = Date.today(),
      SOL_Resultado_Contato__c = 'Atendeu'
      // SOL_Tipo_Tarefa__c em branco -> não é tarefa de contato SOL
    );

    Test.startTest();
    insert manual;
    Test.stopTest();

    System.assertEquals(
      false,
      recarregar(l.Id).SOL_Contato_Efetivado__c,
      'Task sem SOL_Tipo_Tarefa__c não dispara a sinalização.'
    );
    System.assertEquals(1, abertasDe(l.Id), 'A 1ª Ligação continua pendente.');
  }

  // ============================================================ SEM PRAZO / FORA DO HORÁRIO

  @IsTest
  static void aceitaMesmoComPrazoVencidoSemBloqueio() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S5', 'Recuperação Tributária');
    Task pendente = tarefaContatoAberta(l.Id, l.OwnerId);

    Task alvo = new Task(
      Subject = 'Retorno do cliente no fim de semana',
      WhoId = l.Id,
      OwnerId = l.OwnerId,
      Status = 'Open',
      ActivityDate = Date.today().addDays(-10),
      SOL_Prazo_Contato__c = System.now().addDays(-10), // prazo vencido
      SOL_Tipo_Tarefa__c = 'Contato'
    );
    insert alvo;

    Test.startTest();
    concluirComoAtendeu(alvo.Id);
    Test.stopTest();

    System.assertEquals(true, recarregar(l.Id).SOL_Contato_Efetivado__c);
    System.assertEquals(
      'Cancelada',
      [SELECT Status FROM Task WHERE Id = :pendente.Id].Status,
      'Contato fora do prazo cancela normalmente, sem bloqueio.'
    );
  }

  // ============================================================ IDEMPOTÊNCIA / REPROCESSO

  @IsTest
  static void reprocessamentoNaoDuplicaNemFalha() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S6', 'Recuperação Tributária');
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    concluirComoAtendeu(alvo.Id);
    Datetime dataApos1 = recarregar(l.Id).SOL_Data_Contato_Efetivado__c;

    SOLDistribuicaoService.ResultadoContatoEfetivado r = SOLDistribuicaoService.registrarContatoEfetivado(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.leadsSinalizados, 'Já sinalizado: não reprocessa o flag.');
    System.assertEquals(0, r.tarefasCanceladas, 'Nada mais pendente para cancelar.');
    System.assertEquals(
      dataApos1,
      recarregar(l.Id).SOL_Data_Contato_Efetivado__c,
      'A data do contato efetivado não muda no reprocessamento.'
    );
  }

  @IsTest
  static void duasTarefasAtendeuMesmoLeadNaoDuplicam() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S7', 'Recuperação Tributária');
    Task a = tarefaContatoAberta(l.Id, l.OwnerId);
    Task b = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    // Duas tarefas concluídas como "Atendeu" no MESMO DML.
    update new List<Task>{
      new Task(Id = a.Id, Status = 'Completed', SOL_Resultado_Contato__c = 'Atendeu'),
      new Task(Id = b.Id, Status = 'Completed', SOL_Resultado_Contato__c = 'Atendeu')
    };
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(true, d.SOL_Contato_Efetivado__c);
    System.assertEquals(0, abertasDe(l.Id), 'Só a 1ª Ligação restante foi cancelada, uma vez.');
  }

  // ============================================================ BULK

  @IsTest
  static void processamentoBulk() {
    Cenario c = montarCenario(3);
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 10; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rtSOL(),
          LastName = 'Bulk ' + i,
          Company = 'C',
          Status = statusLead(),
          CNPJ__c = CNPJ
        )
      );
    }
    insert leads; // Flow distribui + cria 1ª Ligação (tipo Contato) por Lead

    List<Task> setup = new List<Task>();
    List<Task> alvos = new List<Task>();
    for (Lead l : [SELECT Id, OwnerId FROM Lead WHERE Id IN :leads]) {
      setup.add(
        new Task(
          Subject = 'pendente',
          WhoId = l.Id,
          OwnerId = l.OwnerId,
          Status = 'Open',
          ActivityDate = Date.today(),
          SOL_Prazo_Contato__c = System.now().addMinutes(5),
          SOL_Tipo_Tarefa__c = 'Contato'
        )
      );
      Task alvo = new Task(
        Subject = 'alvo',
        WhoId = l.Id,
        OwnerId = l.OwnerId,
        Status = 'Open',
        ActivityDate = Date.today(),
        SOL_Prazo_Contato__c = System.now(),
        SOL_Tipo_Tarefa__c = 'Contato'
      );
      alvos.add(alvo);
    }
    insert setup;
    insert alvos;

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    List<Task> concluir = new List<Task>();
    for (Task a : alvos) {
      concluir.add(
        new Task(Id = a.Id, Status = 'Completed', SOL_Resultado_Contato__c = 'Atendeu')
      );
    }
    update concluir; // 1 DML -> Flow bulk -> Invocable 1x -> serviço 1x
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    for (Lead d : [SELECT SOL_Contato_Efetivado__c FROM Lead WHERE Id IN :leads]) {
      System.assertEquals(true, d.SOL_Contato_Efetivado__c);
    }
    Integer aindaAbertas = [
      SELECT COUNT()
      FROM Task
      WHERE WhoId IN :leads AND SOL_Tipo_Tarefa__c = 'Contato' AND IsClosed = false
    ];
    System.assertEquals(0, aindaAbertas, 'Todas as pendentes canceladas em bulk.');
    System.assert(soql < 30, 'SOQL não escala por Lead/Task: ' + soql);
    System.assert(dml < 15, 'DML não escala por Lead/Task: ' + dml);
  }

  // ============================================================ ISOLAMENTO

  @IsTest
  static void leadDeOutraBUEhIgnorado() {
    Cenario c = montarCenario(2);
    Lead outra = new Lead(LastName = 'OutraBU', Company = 'C', Status = statusLead());
    insert outra; // sem Record Type SOL

    Task t = new Task(
      Subject = 'x',
      WhoId = outra.Id,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Prazo_Contato__c = System.now(),
      SOL_Tipo_Tarefa__c = 'Contato'
    );
    insert t;

    Test.startTest();
    concluirComoAtendeu(t.Id);
    SOLDistribuicaoService.ResultadoContatoEfetivado r = SOLDistribuicaoService.registrarContatoEfetivado(
      new List<Id>{ outra.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.leadsSinalizados);
    System.assert(r.ignorados >= 1, 'Lead de outra BU é ignorado.');
    System.assertEquals(
      false,
      [SELECT SOL_Contato_Efetivado__c FROM Lead WHERE Id = :outra.Id]
        .SOL_Contato_Efetivado__c
    );
  }

  @IsTest
  static void produtoArt360FuncionaIgual() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S8', 'ART 360');
    Task pendente = tarefaContatoAberta(l.Id, l.OwnerId);
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    concluirComoAtendeu(alvo.Id);
    Test.stopTest();

    System.assertEquals(
      true,
      recarregar(l.Id).SOL_Contato_Efetivado__c,
      'Contato efetivado vale para ART 360 (sem filtro de produto).'
    );
    System.assertEquals(
      'Cancelada',
      [SELECT Status FROM Task WHERE Id = :pendente.Id].Status
    );
  }

  // ============================================================ CHAMADA DIRETA

  @IsTest
  static void colecaoVaziaNulaEConvertidoIgnorados() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S9', 'Recuperação Tributária');
    update new Lead(Id = l.Id, SOL_Status_Procuracao__c = 'Recebida');
    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(l.Id);
    lc.setDoNotCreateOpportunity(true);
    lc.setConvertedStatus(
      [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1].MasterLabel
    );
    Database.convertLead(lc);

    Test.startTest();
    SOLDistribuicaoService.ResultadoContatoEfetivado r1 = SOLDistribuicaoService.registrarContatoEfetivado(
      null
    );
    SOLDistribuicaoService.ResultadoContatoEfetivado r2 = SOLDistribuicaoService.registrarContatoEfetivado(
      new List<Id>()
    );
    SOLDistribuicaoService.ResultadoContatoEfetivado r3 = SOLDistribuicaoService.registrarContatoEfetivado(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r1.leadsSinalizados);
    System.assertEquals(0, r2.leadsSinalizados);
    System.assertEquals(0, r3.leadsSinalizados, 'Lead convertido é ignorado.');
    System.assert(r3.ignorados >= 1);
  }

  // ============================================================ REGRESSÃO

  @IsTest
  static void distribuicaoEReatribuicaoContinuamFuncionando() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('Reg', 'Recuperação Tributária');
    Id ownerInicial = l.OwnerId;

    // A 1ª Ligação criada pela distribuição já vem classificada como Contato.
    List<Task> lig = [
      SELECT SOL_Tipo_Tarefa__c
      FROM Task
      WHERE WhoId = :l.Id AND Subject = '1ª Ligação'
    ];
    System.assertEquals(1, lig.size());
    System.assertEquals('Contato', lig[0].SOL_Tipo_Tarefa__c);

    Test.startTest();
    // 3 negativos -> reatribuição (CLICKUP-9400) continua funcionando.
    insert new List<Task>{
      new Task(WhoId = l.Id, Subject = 'n1', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu'),
      new Task(WhoId = l.Id, Subject = 'n2', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu'),
      new Task(WhoId = l.Id, Subject = 'n3', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu')
    };
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertNotEquals(ownerInicial, d.OwnerId, 'Reatribuição por falta de contato intacta.');
    System.assertEquals(1, d.SOL_Quantidade_Reatribuicoes__c);
    System.assertEquals(
      false,
      d.SOL_Contato_Efetivado__c,
      'Resultado negativo não sinaliza contato efetivado.'
    );
  }
}

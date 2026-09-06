/**
 * CLICKUP-9417 — Testes do cancelamento automático de tarefas de contato
 * pendentes por contato efetivado.
 *
 * O Flow SOL_Contato_Efetivado está ATIVO: concluir uma tarefa de contato SOL
 * (SOL_Tipo_Tarefa__c = 'Contato') com resultado "Atendeu" já dispara a
 * sinalização + cancelamento. Os testes convivem com a automação real e também
 * chamam o serviço diretamente — a operação é idempotente.
 *
 * O serviço roda em contexto de sistema; há também um teste executado como
 * VENDEDOR COM O PERMISSION SET COMERCIAL (PS_SOL_Comercial), comprovando o
 * acesso à classe Invocable e aos campos (ajuste do PR #5).
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
    // CLICKUP-9419: converter exige reunião realizada + procuração Recebida com data + arquivo.
    Task reu9419 = new Task(
      Subject = 'r',
      WhoId = l.Id,
      OwnerId = l.OwnerId,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert reu9419;
    update new Task(Id = reu9419.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    update new Lead(
      Id = l.Id,
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = Date.today()
    );
    ContentVersion cv9419 = new ContentVersion(
      Title = 'p9419',
      PathOnClient = 'p.txt',
      VersionData = Blob.valueOf('x')
    );
    insert cv9419;
    insert new ContentDocumentLink(
      ContentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv9419.Id]
        .ContentDocumentId,
      LinkedEntityId = l.Id,
      ShareType = 'V'
    );
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

  // ============================================================ VENDEDOR COMERCIAL

  private static Id psSolComercialId() {
    return [SELECT Id FROM PermissionSet WHERE Name = 'PS_SOL_Comercial' LIMIT 1].Id;
  }

  private static User vendedorComercial() {
    List<Profile> ps = [
      SELECT Id
      FROM Profile
      WHERE UserType = 'Standard'
      ORDER BY Name
      LIMIT 1
    ];
    return new User(
      FirstName = 'RR',
      LastName = 'Comercial CEf',
      Alias = 'rrcecom',
      Email = 'rr.cecom@arnone.invalid',
      Username = 'rr.cecom.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9417.test.invalid',
      ProfileId = ps.isEmpty() ? UserInfo.getProfileId() : ps[0].Id,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  @IsTest
  static void vendedorComercialDisparaFlowEApex() {
    User comercial = vendedorComercial();
    System.runAs(contextoAtual()) {
      insert comercial;
      insert new PermissionSetAssignment(
        AssigneeId = comercial.Id,
        PermissionSetId = psSolComercialId()
      );
      Group fila = new Group(
        Name = 'RR ContEf Comercial 9417',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      insert new GroupMember(GroupId = fila.Id, UserOrGroupId = comercial.Id);
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;

    Lead l = novoLeadSOLDistribuido('SComercial', 'Recuperação Tributária');
    System.assertEquals(comercial.Id, l.OwnerId, 'Lead distribuído ao vendedor comercial.');
    Task extra = tarefaContatoAberta(l.Id, comercial.Id);
    Task lig = [
      SELECT Id
      FROM Task
      WHERE WhoId = :l.Id AND Subject = '1ª Ligação'
      LIMIT 1
    ];

    Test.startTest();
    // O VENDEDOR (perfil Standard + PS_SOL_Comercial) conclui a própria tarefa.
    System.runAs(new User(Id = comercial.Id)) {
      update new Task(
        Id = lig.Id,
        Status = 'Completed',
        SOL_Resultado_Contato__c = 'Atendeu'
      );
    }
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(
      true,
      d.SOL_Contato_Efetivado__c,
      'Concluir a Task como vendedor comercial dispara o Flow SOL_Contato_Efetivado e o Apex.'
    );
    System.assertNotEquals(null, d.SOL_Data_Contato_Efetivado__c);
    System.assertEquals(
      'Cancelada',
      [SELECT Status FROM Task WHERE Id = :extra.Id].Status,
      'Tarefa de contato pendente cancelada.'
    );
  }

  // ============================================================ VALIDATION RULE (STATUS CANCELADA)

  @IsTest
  static void statusCanceladaExigeClassificacaoSOL() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('SVR', 'Recuperação Tributária');

    // (a) Task de outra BU — sem SOL_Tipo_Tarefa__c — não pode usar "Cancelada".
    Task outra = new Task(
      Subject = 'x',
      WhoId = l.Id,
      OwnerId = l.OwnerId,
      Status = 'Open',
      ActivityDate = Date.today()
    );
    insert outra;

    // (b) Task classificada como Contato mas SEM o motivo do cancelamento.
    Task semMotivo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    Boolean bloqueadoSemTipo = false;
    try {
      update new Task(Id = outra.Id, Status = 'Cancelada');
    } catch (DmlException e) {
      bloqueadoSemTipo = true;
      System.assert(
        e.getMessage().contains('exclusivo das tarefas de automação Arnone Soluções'),
        'Mensagem da VR: ' + e.getMessage()
      );
    }

    Boolean bloqueadoSemMotivo = false;
    try {
      update new Task(Id = semMotivo.Id, Status = 'Cancelada');
    } catch (DmlException e) {
      bloqueadoSemMotivo = true;
    }
    Test.stopTest();

    System.assert(bloqueadoSemTipo, 'Task não classificada não pode usar "Cancelada".');
    System.assert(bloqueadoSemMotivo, '"Cancelada" exige SOL_Motivo_Cancelamento__c.');
  }

  @IsTest
  static void cancelamentoDoServicoPassaNaValidationRule() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('SVRok', 'Recuperação Tributária');
    Task pendente = tarefaContatoAberta(l.Id, l.OwnerId);
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    concluirComoAtendeu(alvo.Id); // serviço seta Status=Cancelada + tipo + motivo
    Test.stopTest();

    Task t = [
      SELECT Status, SOL_Tipo_Tarefa__c, SOL_Motivo_Cancelamento__c
      FROM Task
      WHERE Id = :pendente.Id
    ];
    System.assertEquals('Cancelada', t.Status);
    System.assertEquals('Contato', t.SOL_Tipo_Tarefa__c);
    System.assertEquals('Contato efetivado', t.SOL_Motivo_Cancelamento__c);
  }

  // ============================================================ ATOMICIDADE DA FALHA

  @IsTest
  static void falhaNoCancelamentoAbortaAtomicamente() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('SAtom', 'Recuperação Tributária');
    Task pendente = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    Test.setReadOnlyApplicationMode(true); // qualquer DML/lock falha
    Boolean lancou = false;
    try {
      SOLDistribuicaoService.registrarContatoEfetivado(new List<Id>{ l.Id });
    } catch (SOLDistribuicaoService.ContatoEfetivadoException e) {
      lancou = true;
      System.assertEquals(
        SOLDistribuicaoService.MSG_CONTATO_EFETIVADO_FALHA,
        e.getMessage(),
        'Mensagem controlada, sem detalhe técnico.'
      );
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(
      lancou,
      'A falha NÃO é descartada em silêncio: relança ContatoEfetivadoException.'
    );
    Lead d = recarregar(l.Id);
    System.assertEquals(false, d.SOL_Contato_Efetivado__c, 'Lead não foi sinalizado.');
    System.assertEquals(
      'Open',
      [SELECT Status FROM Task WHERE Id = :pendente.Id].Status,
      'Tarefa pendente intacta (rollback).'
    );
  }

  @IsTest
  static void invocableRelancaAFalhaParaAbortarATransacao() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('SInv', 'Recuperação Tributária');
    tarefaContatoAberta(l.Id, l.OwnerId);

    SOLContatoEfetivadoInvocable.Entrada e = new SOLContatoEfetivadoInvocable.Entrada();
    e.leadId = l.Id;

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      SOLContatoEfetivadoInvocable.registrar(
        new List<SOLContatoEfetivadoInvocable.Entrada>{ e }
      );
    } catch (SOLDistribuicaoService.ContatoEfetivadoException ex) {
      lancou = true;
      System.assertEquals(
        SOLDistribuicaoService.MSG_CONTATO_EFETIVADO_FALHA,
        ex.getMessage()
      );
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(
      lancou,
      'O Invocable relança a falha para o Flow abortar a transação (a Task não fica concluída).'
    );
  }

  // ======================================================================
  //  CLICKUP-9437 — "Atendeu — sem conclusão" e a VR SOL_Atendeu_Exige_Conclusao
  //
  //  Duas coisas entram aqui. A primeira é o estado intermediário que faltava:
  //  o vendedor falou com o lead, mas nada avançou — não é contato efetivado e
  //  não cancela nada, ainda que conte como tentativa. A segunda é o
  //  fechamento de uma brecha antiga: gravar "Atendeu" numa ligação AINDA
  //  ABERTA não produzia efeito nenhum (o Flow exige Completed e a contagem só
  //  lê IsClosed), deixando um Lead com "atendeu" que não efetivava contato nem
  //  bloqueava a reatribuição.
  // ======================================================================

  private static final String RES_SEM_CONCLUSAO = 'Atendeu_Sem_Conclusao';

  /**
   * Ligação dos dias 2/3 (CLICKUP-9434): tipo + canal, e prazo NULO. É o outro
   * braço do recorte da VR — o primeiro é a tarefa legada, com prazo e sem
   * canal, que `tarefaContatoAberta` já produz.
   */
  private static Task ligacaoDeCadenciaAberta(Id leadId, Id owner, Integer dia) {
    Task t = new Task(
      Subject = dia + 'ª Ligação',
      WhoId = leadId,
      OwnerId = owner,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Contato',
      SOL_Canal_Contato__c = 'Ligação',
      SOL_Dia_Cadencia__c = dia
    );
    insert t;
    return t;
  }

  /** Tarefa de mensagem aberta (e-mail ou WhatsApp), para provar o cancelamento. */
  private static Task tarefaDeMensagemAberta(Id leadId, Id owner, String canal) {
    Task t = new Task(
      Subject = canal + ' do dia',
      WhoId = leadId,
      OwnerId = owner,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Contato',
      SOL_Canal_Contato__c = canal,
      SOL_Dia_Cadencia__c = 2
    );
    insert t;
    return t;
  }

  private static Task lerTarefa(Id taskId) {
    return [
      SELECT
        Id,
        Subject,
        Status,
        IsClosed,
        ActivityDate,
        SOL_Prazo_Contato__c,
        SOL_Canal_Contato__c,
        SOL_Tipo_Tarefa__c,
        SOL_Dia_Cadencia__c,
        SOL_Resultado_Contato__c,
        SOL_Motivo_Cancelamento__c
      FROM Task
      WHERE Id = :taskId
    ];
  }

  /**
   * (1) "Atendeu" em ligação AINDA ABERTA é bloqueado — nos DOIS braços do
   * recorte: a tarefa legada (prazo preenchido, canal vazio, anterior ao 9434)
   * e a dos dias 2/3 (tipo + canal, prazo nulo).
   */
  @IsTest
  static void atendeuEmLigacaoAbertaEhBloqueadoNosDoisBracos() {
    montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S9437a', 'Recuperação Tributária');
    Task legada = tarefaContatoAberta(l.Id, l.OwnerId);
    Task dia2 = ligacaoDeCadenciaAberta(l.Id, l.OwnerId, 2);

    // Pré-condições: cada tarefa exercita UM braço, não os dois.
    Task legadaLida = lerTarefa(legada.Id);
    System.assertNotEquals(
      null,
      legadaLida.SOL_Prazo_Contato__c,
      'Pré-condição: a legada tem prazo de contato.'
    );
    System.assertEquals(
      null,
      legadaLida.SOL_Canal_Contato__c,
      'Pré-condição: e NÃO tem canal — o campo nasceu no CLICKUP-9434.'
    );
    Task dia2Lida = lerTarefa(dia2.Id);
    System.assertEquals(
      null,
      dia2Lida.SOL_Prazo_Contato__c,
      'Pré-condição: o dia 2 não tem prazo em minutos.'
    );
    System.assertEquals(
      'Ligação',
      dia2Lida.SOL_Canal_Contato__c,
      'Pré-condição: e é do canal Ligação.'
    );

    Test.startTest();
    Map<Id, String> erros = new Map<Id, String>();
    for (Id alvo : new List<Id>{ legada.Id, dia2.Id }) {
      try {
        update new Task(Id = alvo, SOL_Resultado_Contato__c = 'Atendeu');
        erros.put(alvo, '');
      } catch (DmlException e) {
        erros.put(alvo, e.getMessage());
      }
    }
    Test.stopTest();

    for (Id alvo : erros.keySet()) {
      System.assert(
        erros.get(alvo).contains('apenas ao CONCLUIR'),
        'Gravar "Atendeu" sem concluir tem de ser bloqueado. Recebido: ' +
          erros.get(alvo)
      );
      System.assertEquals(
        null,
        lerTarefa(alvo).SOL_Resultado_Contato__c,
        'E o resultado não fica gravado.'
      );
      System.assertEquals(
        'Open',
        lerTarefa(alvo).Status,
        'A tarefa continua aberta.'
      );
    }
    System.assert(
      recarregar(l.Id).SOL_Contato_Efetivado__c != true,
      'E o Lead não foi sinalizado por uma tarefa que nunca chegou a ser concluída.'
    );
  }

  /**
   * (2) e (3) Concluir com "Atendeu" — Status e resultado no MESMO update —
   * marca o Lead e cancela as pendentes dos TRÊS canais, enquanto a tarefa de
   * origem permanece concluída, com o resultado intacto.
   */
  @IsTest
  static void concluirComAtendeuCancelaOsTresCanaisEPreservaAOrigem() {
    montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S9437b', 'Recuperação Tributária');
    Task ligacao = ligacaoDeCadenciaAberta(l.Id, l.OwnerId, 2);
    Task email = tarefaDeMensagemAberta(l.Id, l.OwnerId, 'E-mail');
    Task whats = tarefaDeMensagemAberta(l.Id, l.OwnerId, 'WhatsApp');

    Test.startTest();
    update new Task(
      Id = ligacao.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Atendeu'
    );
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(true, d.SOL_Contato_Efetivado__c, 'Lead sinalizado.');
    System.assertNotEquals(
      null,
      d.SOL_Data_Contato_Efetivado__c,
      'Data do contato efetivado registrada.'
    );

    Task origem = lerTarefa(ligacao.Id);
    System.assertEquals(
      'Completed',
      origem.Status,
      'A tarefa de origem permanece CONCLUÍDA, não cancelada.'
    );
    System.assertEquals(
      'Atendeu',
      origem.SOL_Resultado_Contato__c,
      'E o resultado dela não é alterado.'
    );

    for (Id alvo : new List<Id>{ email.Id, whats.Id }) {
      Task t = lerTarefa(alvo);
      System.assertEquals(
        'Cancelada',
        t.Status,
        'A pendente do canal ' + t.SOL_Canal_Contato__c + ' é cancelada.'
      );
      System.assertEquals(
        'Contato efetivado',
        t.SOL_Motivo_Cancelamento__c,
        'Com o motivo da automação existente.'
      );
    }
    System.assertEquals(
      0,
      abertasDe(l.Id),
      'Nenhuma tarefa de contato pendente sobra, em canal nenhum.'
    );
  }

  /**
   * (4) "Atendeu — sem conclusão" não efetiva contato: não marca a flag, não
   * preenche a data e não cancela nada. É a diferença inteira entre os dois.
   */
  @IsTest
  static void atendeuSemConclusaoNaoEfetivaContatoNemCancela() {
    montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S9437c', 'Recuperação Tributária');
    Task ligacao = ligacaoDeCadenciaAberta(l.Id, l.OwnerId, 2);
    Task email = tarefaDeMensagemAberta(l.Id, l.OwnerId, 'E-mail');
    Task whats = tarefaDeMensagemAberta(l.Id, l.OwnerId, 'WhatsApp');

    Test.startTest();
    update new Task(
      Id = ligacao.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = RES_SEM_CONCLUSAO
    );
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assert(
      d.SOL_Contato_Efetivado__c != true,
      'Conversa sem avanço NÃO é contato efetivado.'
    );
    System.assertEquals(
      null,
      d.SOL_Data_Contato_Efetivado__c,
      'E não estampa a data do contato efetivado.'
    );

    System.assertEquals(
      RES_SEM_CONCLUSAO,
      lerTarefa(ligacao.Id).SOL_Resultado_Contato__c,
      'O resultado é gravado normalmente ao concluir.'
    );
    for (Id alvo : new List<Id>{ email.Id, whats.Id }) {
      Task t = lerTarefa(alvo);
      System.assertEquals(
        'Open',
        t.Status,
        'A tarefa de ' + t.SOL_Canal_Contato__c + ' continua ABERTA.'
      );
      System.assertEquals(
        null,
        t.SOL_Motivo_Cancelamento__c,
        'E sem motivo de cancelamento.'
      );
    }
  }

  /**
   * "Atendeu" numa tarefa JÁ CANCELADA é bloqueado, e a gravação recusada não
   * deixa rastro: status, motivo e o resto dos dados continuam como estavam.
   *
   * Era o furo da primeira versão da regra, que isentava "Cancelada" junto com
   * "Completed": dava para editar uma tarefa cancelada e produzir exatamente o
   * estado incoerente que este card existe para eliminar — resultado "Atendeu"
   * sem contato efetivado, porque o Flow SOL_Contato_Efetivado exige
   * "Completed" e nunca chega a rodar.
   */
  @IsTest
  static void atendeuEmTarefaJaCanceladaEhBloqueadoSemAlterarNada() {
    montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S9437d', 'Recuperação Tributária');
    Task ligacao = ligacaoDeCadenciaAberta(l.Id, l.OwnerId, 2);
    update new Task(
      Id = ligacao.Id,
      Status = 'Cancelada',
      SOL_Motivo_Cancelamento__c = 'Contato efetivado'
    );

    Task antes = lerTarefa(ligacao.Id);
    System.assertEquals(
      'Cancelada',
      antes.Status,
      'Pré-condição: a tarefa está cancelada.'
    );
    System.assertEquals(
      null,
      antes.SOL_Resultado_Contato__c,
      'Pré-condição: e sem resultado — cancelada não é atendida.'
    );

    Test.startTest();
    String erro = '';
    try {
      update new Task(Id = ligacao.Id, SOL_Resultado_Contato__c = 'Atendeu');
    } catch (DmlException e) {
      erro = e.getMessage();
    }
    Test.stopTest();

    System.assert(
      erro.contains('apenas ao CONCLUIR'),
      'Gravar "Atendeu" numa tarefa cancelada tem de ser bloqueado. Recebido: ' +
        erro
    );

    Task depois = lerTarefa(ligacao.Id);
    System.assertEquals(
      null,
      depois.SOL_Resultado_Contato__c,
      'O resultado não foi gravado.'
    );
    System.assertEquals(antes.Status, depois.Status, 'O status foi preservado.');
    System.assertEquals(
      antes.SOL_Motivo_Cancelamento__c,
      depois.SOL_Motivo_Cancelamento__c,
      'O motivo do cancelamento foi preservado.'
    );
    System.assertEquals(antes.Subject, depois.Subject, 'O assunto foi preservado.');
    System.assertEquals(
      antes.ActivityDate,
      depois.ActivityDate,
      'O vencimento foi preservado.'
    );
    System.assertEquals(
      antes.SOL_Canal_Contato__c,
      depois.SOL_Canal_Contato__c,
      'O canal foi preservado.'
    );
    System.assertEquals(
      antes.SOL_Tipo_Tarefa__c,
      depois.SOL_Tipo_Tarefa__c,
      'O tipo foi preservado.'
    );
    System.assertEquals(
      antes.SOL_Dia_Cadencia__c,
      depois.SOL_Dia_Cadencia__c,
      'O dia da cadência foi preservado.'
    );
    System.assert(
      recarregar(l.Id).SOL_Contato_Efetivado__c != true,
      'E o Lead não foi sinalizado por uma tarefa cancelada.'
    );
  }

  /**
   * Cancelar e marcar "Atendeu" na MESMA gravação é bloqueado por inteiro —
   * mesmo com tipo, canal e motivo válidos, que fariam o cancelamento passar
   * sozinho. E o contraste: concluir com "Atendeu" segue permitido e efetiva o
   * contato normalmente.
   */
  @IsTest
  static void cancelarComAtendeuEhBloqueadoMasConcluirComAtendeuPassa() {
    montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S9437e', 'Recuperação Tributária');
    Task ligacao = ligacaoDeCadenciaAberta(l.Id, l.OwnerId, 2);

    Test.startTest();
    String erro = '';
    try {
      update new Task(
        Id = ligacao.Id,
        Status = 'Cancelada',
        SOL_Motivo_Cancelamento__c = 'Contato efetivado',
        SOL_Resultado_Contato__c = 'Atendeu'
      );
    } catch (DmlException e) {
      erro = e.getMessage();
    }

    Task aposTentativa = lerTarefa(ligacao.Id);
    System.assert(
      erro.contains('apenas ao CONCLUIR'),
      'Cancelar já marcando "Atendeu" tem de ser bloqueado. Recebido: ' + erro
    );
    System.assertEquals(
      'Open',
      aposTentativa.Status,
      'A gravação foi desfeita por inteiro: o status não mudou.'
    );
    System.assertEquals(
      null,
      aposTentativa.SOL_Motivo_Cancelamento__c,
      'Nem o motivo, que sozinho seria válido, sobreviveu.'
    );
    System.assertEquals(
      null,
      aposTentativa.SOL_Resultado_Contato__c,
      'Nem o resultado.'
    );

    // O caminho legítimo continua aberto.
    update new Task(
      Id = ligacao.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Atendeu'
    );
    Test.stopTest();

    Task concluida = lerTarefa(ligacao.Id);
    System.assertEquals('Completed', concluida.Status, 'Concluir é permitido.');
    System.assertEquals(
      'Atendeu',
      concluida.SOL_Resultado_Contato__c,
      'Com o resultado gravado.'
    );
    Lead d = recarregar(l.Id);
    System.assertEquals(
      true,
      d.SOL_Contato_Efetivado__c,
      'E o contato é efetivado normalmente.'
    );
    System.assertNotEquals(
      null,
      d.SOL_Data_Contato_Efetivado__c,
      'Com a data carimbada.'
    );
  }

  /**
   * Os três cancelamentos automáticos continuam funcionando — e a razão é
   * simples: nenhum deles grava "Atendeu". Eles gravam Status e motivo, que a
   * VR não observa. Não foi preciso isentar "Cancelada" para isso.
   */
  @IsTest
  static void cancelamentosAutomaticosContinuamFuncionando() {
    montarCenario(3);
    Lead porContato = novoLeadSOLDistribuido('S9437f', 'Recuperação Tributária');
    Lead porOptOut = novoLeadSOLDistribuido('S9437g', 'Recuperação Tributária');
    Lead porPerda = novoLeadSOLDistribuido('S9437h', 'Recuperação Tributária');

    Map<Id, Task> mensagemPorLead = new Map<Id, Task>();
    for (Lead alvo : new List<Lead>{ porContato, porOptOut, porPerda }) {
      mensagemPorLead.put(
        alvo.Id,
        tarefaDeMensagemAberta(alvo.Id, alvo.OwnerId, 'E-mail')
      );
    }
    Map<Id, Id> ligacaoPorLead = new Map<Id, Id>();
    for (Lead alvo : new List<Lead>{ porContato, porOptOut }) {
      ligacaoPorLead.put(
        alvo.Id,
        ligacaoDeCadenciaAberta(alvo.Id, alvo.OwnerId, 2).Id
      );
    }

    Test.startTest();
    update new Task(
      Id = ligacaoPorLead.get(porContato.Id),
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Atendeu'
    );
    update new Task(
      Id = ligacaoPorLead.get(porOptOut.Id),
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Opt-out'
    );
    update new Lead(
      Id = porPerda.Id,
      Status = 'Desqualificado',
      SOL_Motivo_Desqualificacao__c = 'Negócio perdido'
    );
    Test.stopTest();

    Map<Id, String> motivoEsperado = new Map<Id, String>{
      porContato.Id => 'Contato efetivado',
      porOptOut.Id => 'Opt-out',
      porPerda.Id => 'Negócio perdido'
    };
    for (Id leadId : motivoEsperado.keySet()) {
      Task t = lerTarefa(mensagemPorLead.get(leadId).Id);
      System.assertEquals(
        'Cancelada',
        t.Status,
        'A pendente é cancelada por "' + motivoEsperado.get(leadId) + '".'
      );
      System.assertEquals(
        motivoEsperado.get(leadId),
        t.SOL_Motivo_Cancelamento__c,
        'Com o motivo correto.'
      );
      System.assertEquals(
        null,
        t.SOL_Resultado_Contato__c,
        'E sem resultado de ligação — é por isso que a VR não alcança o cancelamento automático.'
      );
    }
  }

  // ------------------------------------------------------------------ FLS

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

  /**
   * Usuário de perfil STANDARD — e não o de quem roda o teste. FLS efetiva
   * medida sobre um administrador não mede nada: ele vê tudo pelo perfil.
   */
  private static User usuarioStandard(String tag) {
    return new User(
      FirstName = 'CEf',
      LastName = 'Std ' + tag,
      Alias = ('cs' + tag).left(8),
      Email = 'cef.std.' + tag + '@arnone.invalid',
      Username = 'cef.std.' +
        tag +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9437.test.invalid',
      ProfileId = perfilStandard(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private static Id permissionSetId(String nome) {
    return [SELECT Id FROM PermissionSet WHERE Name = :nome LIMIT 1].Id;
  }

  /**
   * (11) FLS do resultado do contato: ESTRUTURAL, pelo que os permission sets
   * declaram, e EFETIVA, medida em runtime sobre usuários de perfil Standard.
   *
   * A medição efetiva é por `getDescribe()` dentro de `System.runAs` porque é o
   * único mecanismo válido em Apex: DML de Apex roda em modo de sistema e NÃO
   * aplica FLS, então um `update` "de verdade" como gestor passaria e daria um
   * falso verde. Não troque estas asserções por DML.
   */
  @IsTest
  static void flsDoResultadoDoContato() {
    Map<String, FieldPermissions> porPs = new Map<String, FieldPermissions>();
    for (FieldPermissions fp : [
      SELECT PermissionsRead, PermissionsEdit, Parent.Name
      FROM FieldPermissions
      WHERE
        Field = 'Task.SOL_Resultado_Contato__c'
        AND Parent.Name IN ('PS_SOL_Comercial', 'PS_SOL_Distribuicao_Admin')
    ]) {
      porPs.put(fp.Parent.Name, fp);
    }

    System.assert(
      porPs.containsKey('PS_SOL_Comercial'),
      'PS_SOL_Comercial declara o resultado do contato.'
    );
    System.assert(
      porPs.get('PS_SOL_Comercial').PermissionsRead,
      'Vendedor lê o resultado do contato.'
    );
    System.assert(
      porPs.get('PS_SOL_Comercial').PermissionsEdit,
      'Vendedor EDITA: é ele quem registra o desfecho da ligação.'
    );
    System.assert(
      porPs.containsKey('PS_SOL_Distribuicao_Admin'),
      'PS_SOL_Distribuicao_Admin passa a declarar o resultado do contato (CLICKUP-9437).'
    );
    System.assert(
      porPs.get('PS_SOL_Distribuicao_Admin').PermissionsRead,
      'Gestor lê o resultado do contato.'
    );
    System.assert(
      !porPs.get('PS_SOL_Distribuicao_Admin').PermissionsEdit,
      'Gestor apenas LÊ: quem registra o desfecho é o vendedor.'
    );

    User vendedorStd = usuarioStandard('v' + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(3));
    User gestorStd = usuarioStandard('g' + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(3));
    System.runAs(contextoAtual()) {
      insert new List<User>{ vendedorStd, gestorStd };
      insert new List<PermissionSetAssignment>{
        new PermissionSetAssignment(
          AssigneeId = vendedorStd.Id,
          PermissionSetId = permissionSetId('PS_SOL_Comercial')
        ),
        new PermissionSetAssignment(
          AssigneeId = gestorStd.Id,
          PermissionSetId = permissionSetId('PS_SOL_Distribuicao_Admin')
        )
      };
    }

    Test.startTest();
    System.runAs(new User(Id = vendedorStd.Id)) {
      Schema.DescribeFieldResult res = Task.SOL_Resultado_Contato__c.getDescribe();
      System.assert(res.isAccessible(), 'Vendedor lê o resultado do contato.');
      System.assert(res.isUpdateable(), 'Vendedor EDITA o resultado do contato.');
    }
    System.runAs(new User(Id = gestorStd.Id)) {
      Schema.DescribeFieldResult res = Task.SOL_Resultado_Contato__c.getDescribe();
      System.assert(res.isAccessible(), 'Gestor lê o resultado do contato.');
      System.assert(
        !res.isUpdateable(),
        'Gestor NÃO edita o resultado do contato.'
      );
    }
    Test.stopTest();

    // O valor novo precisa estar ATIVO na picklist restrita, senão nada grava.
    Set<String> valores = new Set<String>();
    for (
      Schema.PicklistEntry pe : Task.SOL_Resultado_Contato__c.getDescribe()
        .getPicklistValues()
    ) {
      if (pe.isActive()) {
        valores.add(pe.getValue());
      }
    }
    System.assert(
      valores.contains(RES_SEM_CONCLUSAO),
      'O API name "Atendeu_Sem_Conclusao" está ativo no value set restrito.'
    );
    System.assert(
      valores.contains('Atendeu'),
      'E os valores anteriores continuam existindo.'
    );
    System.assertEquals(
      5,
      valores.size(),
      'Cinco valores: os quatro originais mais o novo — nenhum foi removido.'
    );
  }
}

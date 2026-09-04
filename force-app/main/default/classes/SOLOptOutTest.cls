/**
 * CLICKUP-9418 — Testes do opt-out (Lead pede para não ser mais contatado).
 *
 * O Flow SOL_Opt_Out está ATIVO: concluir uma tarefa de contato SOL
 * (SOL_Tipo_Tarefa__c = 'Contato') com resultado "Opt-out" já dispara a
 * desqualificação + cancelamento. Os testes convivem com a automação real e
 * também chamam o serviço diretamente — a operação é idempotente.
 *
 * Há um teste executado como VENDEDOR COM O PERMISSION SET COMERCIAL
 * (PS_SOL_Comercial) e testes de atomicidade da falha e da Validation Rule.
 */
@IsTest
private class SOLOptOutTest {
  private static final String FILA_SINTETICA = 'RR_OptOut_SOL_9418';
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
      LastName = 'OptOutVend ' + i,
      Alias = ('roo' + i).left(8),
      Email = 'rr.oo' + i + '@arnone.invalid',
      Username = 'rr.oo' +
        i +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9418.test.invalid',
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

  private static Cenario montarCenario(Integer qtd) {
    Cenario c = new Cenario();
    List<User> vs = new List<User>();
    for (Integer i = 0; i < qtd; i++) {
      vs.add(vendedor(i));
    }
    System.runAs(contextoAtual()) {
      if (!vs.isEmpty()) {
        insert vs;
      }
      Group fila = new Group(
        Name = 'RR OptOut SOL 9418',
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

  private static Lead novoLeadSOLDistribuido(String nome, String produto, String status) {
    Lead l = new Lead(
      RecordTypeId = rtSOL(),
      LastName = nome,
      Company = 'C',
      Status = String.isBlank(status) ? statusLead() : status,
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
        Status,
        IsConverted,
        SOL_Opt_Out__c,
        SOL_Data_Opt_Out__c,
        SOL_Motivo_Desqualificacao__c,
        SOL_Quantidade_Reatribuicoes__c
      FROM Lead
      WHERE Id = :id
    ];
  }

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

  private static void concluirComoOptOut(Id taskId) {
    update new Task(
      Id = taskId,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Opt-out'
    );
  }

  private static Integer contatoAbertasDe(Id leadId) {
    return [
      SELECT COUNT()
      FROM Task
      WHERE WhoId = :leadId AND SOL_Tipo_Tarefa__c = 'Contato' AND IsClosed = false
    ];
  }

  // ============================================================ POSITIVO

  @IsTest
  static void optOutDesqualificaCancelaPendentesEBloqueiaNovas() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S1', 'Recuperação Tributária', null);
    tarefaContatoAberta(l.Id, l.OwnerId);
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);
    System.assertEquals(3, contatoAbertasDe(l.Id), 'Três tarefas de contato abertas.');

    Test.startTest();
    concluirComoOptOut(alvo.Id);
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(true, d.SOL_Opt_Out__c, 'Lead em opt-out.');
    System.assertNotEquals(null, d.SOL_Data_Opt_Out__c);
    System.assertEquals('Desqualificado', d.Status, 'Lead desqualificado.');
    System.assertEquals('Opt-out', d.SOL_Motivo_Desqualificacao__c);
    System.assertEquals(0, contatoAbertasDe(l.Id), 'Nenhuma tarefa de contato pendente.');

    for (Task t : [
      SELECT Id, Status, SOL_Motivo_Cancelamento__c
      FROM Task
      WHERE WhoId = :l.Id AND SOL_Tipo_Tarefa__c = 'Contato'
    ]) {
      if (t.Id == alvo.Id) {
        System.assertEquals('Completed', t.Status, 'A tarefa do opt-out fica concluída.');
      } else {
        System.assertEquals('Cancelada', t.Status);
        System.assertEquals('Opt-out', t.SOL_Motivo_Cancelamento__c);
      }
    }

    // Nenhuma nova tarefa de contato é criada.
    SOLDistribuicaoService.Resultado rd = SOLDistribuicaoService.distribuir(
      new List<Id>{ l.Id }
    );
    SOLDistribuicaoService.ResultadoReatribuicao rr = SOLDistribuicaoService.reatribuirPorFaltaDeContato(
      new List<Id>{ l.Id }
    );
    System.assertEquals(0, rd.distribuidos);
    System.assertEquals(0, rr.reatribuidos);
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = '1ª Ligação' AND IsClosed = false],
      'Nenhuma nova "1ª Ligação" aberta.'
    );
  }

  @IsTest
  static void tarefasJaConcluidasNaoSaoAlteradas() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S2', 'ART 360', null);

    Task antiga = tarefaContatoAberta(l.Id, l.OwnerId);
    update new Task(
      Id = antiga.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Não atendeu'
    );
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    concluirComoOptOut(alvo.Id);
    Test.stopTest();

    Task rel = [
      SELECT Status, SOL_Resultado_Contato__c, SOL_Motivo_Cancelamento__c
      FROM Task
      WHERE Id = :antiga.Id
    ];
    System.assertEquals('Completed', rel.Status);
    System.assertEquals('Não atendeu', rel.SOL_Resultado_Contato__c);
    System.assertEquals(null, rel.SOL_Motivo_Cancelamento__c);
  }

  @IsTest
  static void tarefaNaoContatoNaoEhTocada() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S3', 'ART 360', null);
    Task naoContato = new Task(
      Subject = 'Reunião comercial',
      WhoId = l.Id,
      OwnerId = l.OwnerId,
      Status = 'Open',
      ActivityDate = Date.today()
    );
    insert naoContato;
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    concluirComoOptOut(alvo.Id);
    Test.stopTest();

    System.assertEquals(
      'Open',
      [SELECT Status FROM Task WHERE Id = :naoContato.Id].Status,
      'Encerramento geral de tarefas é escopo do CLICKUP-9425, não do 9418.'
    );
  }

  // ============================================================ CONTRADIÇÃO / VR

  @IsTest
  static void recuperacaoTributariaEmRecebidoMQLSemCompromisso() {
    Cenario c = montarCenario(2);
    // Lead que dispararia a VR SOL_Recuperacao_Exige_Compromisso ao sair de
    // "Recebido - MQL" sem compromisso — o opt-out precisa passar mesmo assim.
    Lead l = novoLeadSOLDistribuido('S4', 'Recuperação Tributária', 'Recebido - MQL');
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    concluirComoOptOut(alvo.Id);
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals('Desqualificado', d.Status, 'Opt-out desqualifica mesmo em Recebido-MQL sem compromisso.');
    System.assertEquals(true, d.SOL_Opt_Out__c);
    System.assertEquals('Opt-out', d.SOL_Motivo_Desqualificacao__c);
  }

  @IsTest
  static void desqualificacaoManualSemCompromissoContinuaBloqueada() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S4m', 'Recuperação Tributária', 'Recebido - MQL');

    Test.startTest();
    Boolean bloqueou = false;
    try {
      // Perda manual, sem opt-out e sem compromisso: segue bloqueada. Desde o
      // D2 da homologação E2E duas regras cobrem este mesmo desvio — a de
      // compromisso (CLICKUP-9418) e a de coerência do motivo (D2) —, e a
      // mensagem devolvida é a da primeira que a plataforma reportar.
      update new Lead(Id = l.Id, Status = 'Desqualificado');
    } catch (DmlException e) {
      bloqueou = true;
      System.assert(
        e.getMessage().contains('compromisso registrado') ||
        e.getMessage().contains('Motivo da desqualificação incoerente'),
        'Mensagem inesperada: ' + e.getMessage()
      );
    }
    Test.stopTest();

    System.assert(bloqueou, 'Desqualificação manual sem compromisso deve continuar bloqueada.');
    System.assertEquals('Recebido - MQL', recarregar(l.Id).Status);
  }

  @IsTest
  static void desqualificadoComMotivoOptOutMasSemFlagNaoRecebeExcecao() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S4f', 'Recuperação Tributária', 'Recebido - MQL');

    Test.startTest();
    Boolean bloqueou = false;
    try {
      // Motivo "Opt-out" preenchido à mão, mas SOL_Opt_Out__c continua falso:
      // a exceção da VR exige os três sinais juntos.
      update new Lead(
        Id = l.Id,
        Status = 'Desqualificado',
        SOL_Motivo_Desqualificacao__c = 'Opt-out'
      );
    } catch (DmlException e) {
      bloqueou = true;
    }
    Test.stopTest();

    System.assert(
      bloqueou,
      'Sem SOL_Opt_Out__c = true a exceção não se aplica — a perda continua bloqueada.'
    );
  }

  @IsTest
  static void desqualificadoComFlagMasSemMotivoNaoRecebeExcecao() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S4a', 'Recuperação Tributária', 'Recebido - MQL');

    Test.startTest();
    Boolean bloqueou = false;
    try {
      // Flag marcada, mas motivo ausente: a exceção da VR não se aplica.
      update new Lead(
        Id = l.Id,
        Status = 'Desqualificado',
        SOL_Opt_Out__c = true
      );
    } catch (DmlException e) {
      bloqueou = true;
    }
    Test.stopTest();

    System.assert(
      bloqueou,
      'Sem o motivo "Opt-out" a exceção não se aplica — a perda continua bloqueada.'
    );
  }

  @IsTest
  static void produtoArt360FuncionaIgual() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S5', 'ART 360', null);
    Task pendente = tarefaContatoAberta(l.Id, l.OwnerId);
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    concluirComoOptOut(alvo.Id);
    Test.stopTest();

    System.assertEquals('Desqualificado', recarregar(l.Id).Status);
    System.assertEquals(
      'Cancelada',
      [SELECT Status FROM Task WHERE Id = :pendente.Id].Status
    );
  }

  // ============================================================ SEM PRAZO

  @IsTest
  static void optOutForaDoPrazoNaoBloqueia() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S6', 'ART 360', null);
    Task pendente = tarefaContatoAberta(l.Id, l.OwnerId);
    Task alvo = new Task(
      Subject = 'Retorno do cliente no fim de semana',
      WhoId = l.Id,
      OwnerId = l.OwnerId,
      Status = 'Open',
      ActivityDate = Date.today().addDays(-10),
      SOL_Prazo_Contato__c = System.now().addDays(-10),
      SOL_Tipo_Tarefa__c = 'Contato'
    );
    insert alvo;

    Test.startTest();
    concluirComoOptOut(alvo.Id);
    Test.stopTest();

    System.assertEquals('Desqualificado', recarregar(l.Id).Status);
    System.assertEquals(
      'Cancelada',
      [SELECT Status FROM Task WHERE Id = :pendente.Id].Status
    );
  }

  // ============================================================ IDEMPOTÊNCIA

  @IsTest
  static void reprocessamentoNaoDuplicaNemFalha() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S7', 'ART 360', null);
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    concluirComoOptOut(alvo.Id);
    Datetime dataApos1 = recarregar(l.Id).SOL_Data_Opt_Out__c;

    SOLDistribuicaoService.ResultadoOptOut r = SOLDistribuicaoService.registrarOptOut(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.leadsDesqualificados, 'Já em opt-out: não reprocessa.');
    System.assertEquals(0, r.tarefasCanceladas);
    System.assertEquals(dataApos1, recarregar(l.Id).SOL_Data_Opt_Out__c);
  }

  @IsTest
  static void duasTarefasOptOutMesmoLeadNaoDuplicam() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S8', 'ART 360', null);
    Task a = tarefaContatoAberta(l.Id, l.OwnerId);
    Task b = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    update new List<Task>{
      new Task(Id = a.Id, Status = 'Completed', SOL_Resultado_Contato__c = 'Opt-out'),
      new Task(Id = b.Id, Status = 'Completed', SOL_Resultado_Contato__c = 'Opt-out')
    };
    Test.stopTest();

    System.assertEquals('Desqualificado', recarregar(l.Id).Status);
    System.assertEquals(0, contatoAbertasDe(l.Id));
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
    insert leads;

    List<Task> setup = new List<Task>();
    List<Task> alvos = new List<Task>();
    for (Lead l : [SELECT Id, OwnerId FROM Lead WHERE Id IN :leads]) {
      setup.add(
        new Task(
          Subject = 'p',
          WhoId = l.Id,
          OwnerId = l.OwnerId,
          Status = 'Open',
          ActivityDate = Date.today(),
          SOL_Prazo_Contato__c = System.now().addMinutes(5),
          SOL_Tipo_Tarefa__c = 'Contato'
        )
      );
      alvos.add(
        new Task(
          Subject = 'alvo',
          WhoId = l.Id,
          OwnerId = l.OwnerId,
          Status = 'Open',
          ActivityDate = Date.today(),
          SOL_Prazo_Contato__c = System.now(),
          SOL_Tipo_Tarefa__c = 'Contato'
        )
      );
    }
    insert setup;
    insert alvos;

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    List<Task> concluir = new List<Task>();
    for (Task a : alvos) {
      concluir.add(
        new Task(Id = a.Id, Status = 'Completed', SOL_Resultado_Contato__c = 'Opt-out')
      );
    }
    update concluir;
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    for (Lead d : [SELECT Status, SOL_Opt_Out__c FROM Lead WHERE Id IN :leads]) {
      System.assertEquals(true, d.SOL_Opt_Out__c);
      System.assertEquals('Desqualificado', d.Status);
    }
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId IN :leads AND SOL_Tipo_Tarefa__c = 'Contato' AND IsClosed = false]
    );
    System.assert(soql < 30, 'SOQL não escala por Lead/Task: ' + soql);
    System.assert(dml < 15, 'DML não escala por Lead/Task: ' + dml);
  }

  // ============================================================ ISOLAMENTO

  @IsTest
  static void leadDeOutraBUEhIgnorado() {
    Cenario c = montarCenario(2);
    Lead outra = new Lead(LastName = 'OutraBU', Company = 'C', Status = statusLead());
    insert outra;
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
    concluirComoOptOut(t.Id);
    SOLDistribuicaoService.ResultadoOptOut r = SOLDistribuicaoService.registrarOptOut(
      new List<Id>{ outra.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.leadsDesqualificados);
    System.assert(r.ignorados >= 1);
    System.assertEquals(
      false,
      [SELECT SOL_Opt_Out__c FROM Lead WHERE Id = :outra.Id].SOL_Opt_Out__c
    );
  }

  // ============================================================ CHAMADA DIRETA

  @IsTest
  static void colecaoVaziaNulaEConvertidoIgnorados() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('S9', 'Recuperação Tributária', null);
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
    SOLDistribuicaoService.ResultadoOptOut r1 = SOLDistribuicaoService.registrarOptOut(null);
    SOLDistribuicaoService.ResultadoOptOut r2 = SOLDistribuicaoService.registrarOptOut(new List<Id>());
    SOLDistribuicaoService.ResultadoOptOut r3 = SOLDistribuicaoService.registrarOptOut(new List<Id>{ l.Id });
    Test.stopTest();

    System.assertEquals(0, r1.leadsDesqualificados);
    System.assertEquals(0, r2.leadsDesqualificados);
    System.assertEquals(0, r3.leadsDesqualificados, 'Lead convertido é ignorado.');
    System.assert(r3.ignorados >= 1);
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
      LastName = 'Comercial OptOut',
      Alias = 'rroocom',
      Email = 'rr.oocom@arnone.invalid',
      Username = 'rr.oocom.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9418.test.invalid',
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
        Name = 'RR OptOut Comercial 9418',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      insert new GroupMember(GroupId = fila.Id, UserOrGroupId = comercial.Id);
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;

    Lead l = novoLeadSOLDistribuido('SComercial', 'ART 360', null);
    System.assertEquals(comercial.Id, l.OwnerId);
    Task extra = tarefaContatoAberta(l.Id, comercial.Id);
    Task lig = [
      SELECT Id
      FROM Task
      WHERE WhoId = :l.Id AND Subject = '1ª Ligação'
      LIMIT 1
    ];

    Test.startTest();
    System.runAs(new User(Id = comercial.Id)) {
      update new Task(
        Id = lig.Id,
        Status = 'Completed',
        SOL_Resultado_Contato__c = 'Opt-out'
      );
    }
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(true, d.SOL_Opt_Out__c, 'Vendedor comercial dispara o Flow + Apex.');
    System.assertEquals('Desqualificado', d.Status);
    System.assertEquals(
      'Cancelada',
      [SELECT Status FROM Task WHERE Id = :extra.Id].Status
    );
  }

  private static Id psSolDistribuicaoAdminId() {
    return [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'PS_SOL_Distribuicao_Admin'
      LIMIT 1
    ]
    .Id;
  }

  private static User usuarioStandard(String sobrenome, String alias) {
    List<Profile> ps = [
      SELECT Id
      FROM Profile
      WHERE UserType = 'Standard'
      ORDER BY Name
      LIMIT 1
    ];
    return new User(
      FirstName = 'RR',
      LastName = sobrenome,
      Alias = alias,
      Email = 'rr.' + alias + '@arnone.invalid',
      Username = 'rr.' +
        alias +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9418.test.invalid',
      ProfileId = ps.isEmpty() ? UserInfo.getProfileId() : ps[0].Id,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private static void assertVeSemEditar(String rotulo) {
    Map<String, Schema.SObjectField> f = Schema.SObjectType.Lead.fields.getMap();
    for (String campo : new List<String>{
      'SOL_Opt_Out__c',
      'SOL_Data_Opt_Out__c',
      'SOL_Motivo_Desqualificacao__c'
    }) {
      Schema.DescribeFieldResult d = f.get(campo).getDescribe();
      System.assert(
        d.isAccessible(),
        rotulo + ' deveria enxergar ' + campo
      );
      System.assert(
        !d.isUpdateable(),
        rotulo + ' NÃO deveria poder editar ' + campo
      );
    }
  }

  @IsTest
  static void vendedorEGestorVeemMotivoFlagEDataSemEditar() {
    User comercial = usuarioStandard('Comercial FLS', 'roofls1');
    User gestor = usuarioStandard('Gestor FLS', 'roofls2');
    System.runAs(contextoAtual()) {
      insert new List<User>{ comercial, gestor };
      insert new List<PermissionSetAssignment>{
        new PermissionSetAssignment(
          AssigneeId = comercial.Id,
          PermissionSetId = psSolComercialId()
        ),
        new PermissionSetAssignment(
          AssigneeId = gestor.Id,
          PermissionSetId = psSolDistribuicaoAdminId()
        )
      };
    }

    Test.startTest();
    System.runAs(new User(Id = comercial.Id)) {
      assertVeSemEditar('Vendedor (PS_SOL_Comercial)');
    }
    System.runAs(new User(Id = gestor.Id)) {
      assertVeSemEditar('Gestor (PS_SOL_Distribuicao_Admin)');
    }
    Test.stopTest();
  }

  // ============================================================ VALIDATION RULE

  @IsTest
  static void cancelamentoOptOutPassaNaValidationRuleCancelada() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('SVR', 'ART 360', null);
    Task pendente = tarefaContatoAberta(l.Id, l.OwnerId);
    Task alvo = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    concluirComoOptOut(alvo.Id);
    Test.stopTest();

    Task t = [
      SELECT Status, SOL_Tipo_Tarefa__c, SOL_Motivo_Cancelamento__c
      FROM Task
      WHERE Id = :pendente.Id
    ];
    System.assertEquals('Cancelada', t.Status);
    System.assertEquals('Contato', t.SOL_Tipo_Tarefa__c);
    System.assertEquals('Opt-out', t.SOL_Motivo_Cancelamento__c);
  }

  // ============================================================ ATOMICIDADE

  @IsTest
  static void falhaNoOptOutAbortaAtomicamente() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('SAtom', 'ART 360', null);
    Task pendente = tarefaContatoAberta(l.Id, l.OwnerId);

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      SOLDistribuicaoService.registrarOptOut(new List<Id>{ l.Id });
    } catch (SOLDistribuicaoService.OptOutException e) {
      lancou = true;
      System.assertEquals(SOLDistribuicaoService.MSG_OPT_OUT_FALHA, e.getMessage());
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'Falha relança OptOutException (não descarta em silêncio).');
    Lead d = recarregar(l.Id);
    System.assertEquals(false, d.SOL_Opt_Out__c, 'Lead não foi desqualificado.');
    System.assertNotEquals('Desqualificado', d.Status);
    System.assertEquals(
      'Open',
      [SELECT Status FROM Task WHERE Id = :pendente.Id].Status,
      'Tarefa pendente intacta (rollback).'
    );
  }

  @IsTest
  static void invocableIgnoraEntradasInvalidas() {
    Test.startTest();
    SOLOptOutInvocable.registrar(null);
    SOLOptOutInvocable.registrar(new List<SOLOptOutInvocable.Entrada>());
    SOLOptOutInvocable.Entrada semId = new SOLOptOutInvocable.Entrada();
    semId.leadId = null;
    SOLOptOutInvocable.registrar(
      new List<SOLOptOutInvocable.Entrada>{ semId, null }
    );
    Test.stopTest();
    // Sem exceção: os guards retornam cedo, sem desqualificar nenhum Lead.
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Lead WHERE SOL_Opt_Out__c = TRUE],
      'Entrada inválida não desqualifica ninguém.'
    );
  }

  @IsTest
  static void invocableRelancaAFalha() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOLDistribuido('SInv', 'ART 360', null);
    tarefaContatoAberta(l.Id, l.OwnerId);

    SOLOptOutInvocable.Entrada e = new SOLOptOutInvocable.Entrada();
    e.leadId = l.Id;

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      SOLOptOutInvocable.registrar(new List<SOLOptOutInvocable.Entrada>{ e });
    } catch (SOLDistribuicaoService.OptOutException ex) {
      lancou = true;
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'O Invocable relança a falha para o Flow abortar a transação.');
  }

  // ============================================================ REGRESSÃO

  @IsTest
  static void distribuicaoEReatribuicaoContinuamFuncionandoSemOptOut() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('Reg', 'ART 360', null);
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    insert new List<Task>{
      new Task(WhoId = l.Id, Subject = 'n1', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu'),
      new Task(WhoId = l.Id, Subject = 'n2', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu'),
      new Task(WhoId = l.Id, Subject = 'n3', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu')
    };
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertNotEquals(ownerInicial, d.OwnerId, 'Reatribuição por falta de contato intacta.');
    System.assertEquals(1, d.SOL_Quantidade_Reatribuicoes__c);
    System.assertEquals(false, d.SOL_Opt_Out__c);
    System.assertNotEquals('Desqualificado', d.Status);
  }
}

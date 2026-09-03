/**
 * CLICKUP-9419 — Testes do Flow SOL_Consolidar_Reuniao_Realizada.
 *
 * Quando uma Task de "Reunião comercial" é concluída (Status = "Completed",
 * SOL_Resultado_Reuniao__c = "Realizada", CompletedDateTime preenchido, WhoId em
 * um Lead RT SOL), o CompletedDateTime é copiado para
 * Lead.SOL_Data_Reuniao_Realizada__c — SÓ se o campo ainda estiver vazio
 * (preserva a PRIMEIRA reunião realizada).
 */
@IsTest
private class SOLConsolidarReuniaoTest {
  private static final String CNPJ = '11222333000181';

  private static Id rtSOL() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Lead novoLeadSOL(String produto) {
    Lead l = new Lead(
      RecordTypeId = rtSOL(),
      LastName = 'C ' + Math.abs(Crypto.getRandomInteger()),
      Company = 'C',
      Status = 'Captação - Contato',
      CNPJ__c = CNPJ,
      SOL_Produto_Interesse__c = produto
    );
    insert l;
    return l;
  }

  private static Task reuniaoAberta(Id leadId) {
    Task t = new Task(
      Subject = 'Realizar reunião comercial',
      WhoId = leadId,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert t;
    return t;
  }

  private static Datetime dataConsolidada(Id leadId) {
    return [SELECT SOL_Data_Reuniao_Realizada__c FROM Lead WHERE Id = :leadId]
      .SOL_Data_Reuniao_Realizada__c;
  }

  // ============================================================ CONSOLIDA

  @IsTest
  static void concluirRealizadaConsolidaCompletedDateTime() {
    Lead l = novoLeadSOL('ART 360');
    Task t = reuniaoAberta(l.Id);

    Test.startTest();
    update new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    Test.stopTest();

    Datetime cdt = [SELECT CompletedDateTime FROM Task WHERE Id = :t.Id].CompletedDateTime;
    System.assertNotEquals(null, cdt);
    System.assertEquals(cdt, dataConsolidada(l.Id), 'A data consolidada = CompletedDateTime da Task.');
  }

  @IsTest
  static void consolidaEmRecuperacaoTributaria() {
    Lead l = novoLeadSOL('Recuperação Tributária');
    Task t = reuniaoAberta(l.Id);
    Test.startTest();
    update new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    Test.stopTest();
    System.assertNotEquals(null, dataConsolidada(l.Id));
  }

  // ============================================================ NÃO CONSOLIDA

  @IsTest
  static void tarefaAbertaNaoConsolida() {
    Lead l = novoLeadSOL('ART 360');
    Test.startTest();
    reuniaoAberta(l.Id);
    Test.stopTest();
    System.assertEquals(null, dataConsolidada(l.Id));
  }

  @IsTest
  static void outroTipoDeTarefaNaoConsolida() {
    Lead l = novoLeadSOL('ART 360');
    Task t = new Task(
      Subject = 'x',
      WhoId = l.Id,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Contato'
    );
    insert t;
    Test.startTest();
    update new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    Test.stopTest();
    System.assertEquals(null, dataConsolidada(l.Id));
  }

  @IsTest
  static void naoCompareceuNaoConsolida() {
    Lead l = novoLeadSOL('Recuperação Tributária');
    Task t = reuniaoAberta(l.Id);
    Test.startTest();
    update new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Não compareceu');
    Test.stopTest();
    System.assertEquals(null, dataConsolidada(l.Id));
  }

  @IsTest
  static void resultadoVazioNaoConsolida() {
    Lead l = novoLeadSOL('ART 360');
    Task t = reuniaoAberta(l.Id);
    Test.startTest();
    update new Task(Id = t.Id, Status = 'Completed');
    Test.stopTest();
    System.assertEquals(null, dataConsolidada(l.Id));
  }

  @IsTest
  static void canceladaNaoConsolida() {
    Lead l = novoLeadSOL('ART 360');
    Task t = reuniaoAberta(l.Id);
    Test.startTest();
    update new Task(
      Id = t.Id,
      Status = 'Cancelada',
      SOL_Motivo_Cancelamento__c = 'Opt-out',
      SOL_Resultado_Reuniao__c = 'Realizada'
    );
    Test.stopTest();
    System.assertEquals(null, dataConsolidada(l.Id));
  }

  @IsTest
  static void outraBUNaoConsolida() {
    Lead outra = new Lead(LastName = 'OutraBU', Company = 'C', Status = 'Novo');
    insert outra;
    Task t = new Task(
      Subject = 'x',
      WhoId = outra.Id,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert t;
    Test.startTest();
    update new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    Test.stopTest();
    System.assertEquals(
      null,
      [SELECT SOL_Data_Reuniao_Realizada__c FROM Lead WHERE Id = :outra.Id]
        .SOL_Data_Reuniao_Realizada__c
    );
  }

  // ============================================================ PRESERVA A PRIMEIRA

  @IsTest
  static void reprocessamentoNaoSobrescreve() {
    Lead l = novoLeadSOL('ART 360');
    Task t = reuniaoAberta(l.Id);
    update new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    Datetime primeira = dataConsolidada(l.Id);
    System.assertNotEquals(null, primeira);

    Test.startTest();
    // reprocessa a MESMA task
    update new Task(Id = t.Id, Description = 'toque qualquer');
    Test.stopTest();

    System.assertEquals(primeira, dataConsolidada(l.Id), 'Reprocessamento não sobrescreve.');
  }

  @IsTest
  static void reuniaoPosteriorNaoSobrescreve() {
    Lead l = novoLeadSOL('Recuperação Tributária');
    Task t1 = reuniaoAberta(l.Id);
    update new Task(Id = t1.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    Datetime primeira = dataConsolidada(l.Id);

    Test.startTest();
    Task t2 = reuniaoAberta(l.Id);
    update new Task(Id = t2.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    Test.stopTest();

    System.assertEquals(primeira, dataConsolidada(l.Id), 'Uma reunião posterior não sobrescreve a primeira.');
  }

  // ============================================================ LOTE

  @IsTest
  static void loteDeTasksELeads() {
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 20; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rtSOL(),
          LastName = 'Lote ' + i,
          Company = 'C',
          Status = 'Captação - Contato',
          CNPJ__c = CNPJ,
          SOL_Produto_Interesse__c = (Math.mod(i, 2) == 0 ? 'ART 360' : 'Recuperação Tributária')
        )
      );
    }
    insert leads;

    List<Task> ts = new List<Task>();
    for (Lead l : leads) {
      ts.add(
        new Task(
          Subject = 'r',
          WhoId = l.Id,
          OwnerId = UserInfo.getUserId(),
          Status = 'Open',
          ActivityDate = Date.today(),
          SOL_Tipo_Tarefa__c = 'Reunião comercial'
        )
      );
    }
    insert ts;

    List<Task> concluir = new List<Task>();
    for (Task t : ts) {
      concluir.add(new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada'));
    }

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    update concluir;
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    System.assertEquals(
      20,
      [SELECT COUNT() FROM Lead WHERE Id IN :leads AND SOL_Data_Reuniao_Realizada__c != null]
    );
    System.assert(soql < 20, 'Get Records bulkificado: ' + soql);
    System.assert(dml < 12, 'Update bulkificado: ' + dml);
  }

  // ============================================================ FLS

  @IsTest
  static void campoTecnicoSomenteLeituraParaVendedorEGestor() {
    Profile p;
    for (Profile pr : [SELECT Id, Name FROM Profile WHERE UserType = 'Standard']) {
      if (pr.Name == 'Standard User') {
        p = pr;
      }
    }
    if (p == null) {
      p = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
    }
    User vend = usuario(p.Id, 'Vend');
    User gestor = usuario(p.Id, 'Gestor');
    insert new List<User>{ vend, gestor };
    insert new List<PermissionSetAssignment>{
      new PermissionSetAssignment(
        AssigneeId = vend.Id,
        PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'PS_SOL_Comercial' LIMIT 1].Id
      ),
      new PermissionSetAssignment(
        AssigneeId = gestor.Id,
        PermissionSetId = [
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'PS_SOL_Distribuicao_Admin'
          LIMIT 1
        ]
        .Id
      )
    };

    Test.startTest();
    System.runAs(vend) {
      assertLeituraSemEdicao('Vendedor (PS_SOL_Comercial)');
    }
    System.runAs(gestor) {
      assertLeituraSemEdicao('Gestor (PS_SOL_Distribuicao_Admin)');
    }
    Test.stopTest();
  }

  private static User usuario(Id profileId, String sobrenome) {
    String alias = ('c' + sobrenome).left(8);
    return new User(
      FirstName = 'RR',
      LastName = sobrenome,
      Alias = alias,
      Email = 'rr.' + alias + '@arnone.invalid',
      Username = 'rr.' +
        alias +
        '.' +
        Math.abs(Crypto.getRandomInteger()) +
        '@arnone.clickup9419c.test.invalid',
      ProfileId = profileId,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private static void assertLeituraSemEdicao(String rotulo) {
    Schema.DescribeFieldResult d = Schema.SObjectType.Lead.fields.getMap()
      .get('SOL_Data_Reuniao_Realizada__c')
      .getDescribe();
    System.assert(d.isAccessible(), rotulo + ' deveria enxergar SOL_Data_Reuniao_Realizada__c.');
    System.assert(!d.isUpdateable(), rotulo + ' NÃO deveria poder editar SOL_Data_Reuniao_Realizada__c.');
  }
}

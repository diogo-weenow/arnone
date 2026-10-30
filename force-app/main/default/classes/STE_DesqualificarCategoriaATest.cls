/**
 * Cobre o Flow STE_Desqualificar_Lead_Categoria_A (before-save em Lead).
 * O valor da picklist Tipo_de_CNH__c tem DOIS espaços entre "CATEGORIA:" e "A";
 * os testes usam a constante exatamente como está na org e o T10 trava isso.
 */
@IsTest
private class STE_DesqualificarCategoriaATest {
  private static final String CATEGORIA_A = 'CATEGORIA:  A';
  private static final String DEFINITIVA = '(B+) DEFINITIVA';
  private static final String PROVISORIA = '(B+) PROVISÓRIA';
  private static final String DESQUALIFICADO = 'Desqualificado';
  private static final String MOTIVO_A = 'Categoria A/ sem CNH';
  private static final String MOTIVO_FAIXA = 'Fora da faixa etária';

  private static Id rt(String developerName) {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get(developerName)
      .getRecordTypeId();
  }

  private static Lead novoSTE(String sobrenome, String status, String tipoCnh) {
    return new Lead(
      RecordTypeId = rt('STE'),
      FirstName = 'Candidato',
      LastName = sobrenome,
      Company = 'Candidato ' + sobrenome,
      MobilePhone = '11988887777',
      Status = status,
      Tipo_de_CNH__c = tipoCnh
    );
  }

  private static Lead recarregar(Id id) {
    return [
      SELECT Id, Status, STE_Motivo_Desqualificacao__c, Tipo_de_CNH__c
      FROM Lead
      WHERE Id = :id
    ];
  }

  private static void assertDesqualificadoPorA(Lead l, String cenario) {
    Assert.areEqual(DESQUALIFICADO, l.Status, cenario + ': Status deveria ser Desqualificado.');
    Assert.areEqual(MOTIVO_A, l.STE_Motivo_Desqualificacao__c, cenario + ': motivo deveria ser Categoria A.');
  }

  @IsTest
  static void t1InsertComCategoriaADesqualifica() {
    Lead l = novoSTE('T1', 'Novo', CATEGORIA_A);
    Test.startTest();
    insert l;
    Test.stopTest();
    assertDesqualificadoPorA(recarregar(l.Id), 'T1');
  }

  @IsTest
  static void t2UpdateParaCategoriaADesqualifica() {
    Lead l = novoSTE('T2', 'Novo', null);
    insert l;
    Assert.areEqual('Novo', recarregar(l.Id).Status, 'T2: sem Tipo, o Lead deveria seguir Novo.');

    Test.startTest();
    update new Lead(Id = l.Id, Tipo_de_CNH__c = CATEGORIA_A);
    Test.stopTest();
    assertDesqualificadoPorA(recarregar(l.Id), 'T2');
  }

  @IsTest
  static void t3QualificadoNaoConvertidoDesqualifica() {
    Lead qualificado = novoSTE('T3a', 'Qualificado', DEFINITIVA);
    Lead validacao = novoSTE('T3b', 'Validação', DEFINITIVA);
    insert new List<Lead>{ qualificado, validacao };

    Test.startTest();
    update new List<Lead>{
      new Lead(Id = qualificado.Id, Tipo_de_CNH__c = CATEGORIA_A),
      new Lead(Id = validacao.Id, Tipo_de_CNH__c = CATEGORIA_A)
    };
    Test.stopTest();
    assertDesqualificadoPorA(recarregar(qualificado.Id), 'T3 Qualificado');
    assertDesqualificadoPorA(recarregar(validacao.Id), 'T3 Validação');
  }

  @IsTest
  static void t4CategoriaBNaoMuda() {
    Lead leadDefinitiva = novoSTE('T4a', 'Novo', DEFINITIVA);
    Lead leadProvisoria = novoSTE('T4b', 'Novo', null);
    insert new List<Lead>{ leadDefinitiva, leadProvisoria };

    Test.startTest();
    update new Lead(Id = leadProvisoria.Id, Tipo_de_CNH__c = PROVISORIA);
    Test.stopTest();

    Set<Id> ids = new Set<Id>{ leadDefinitiva.Id, leadProvisoria.Id };
    for (Lead l : [SELECT Status, STE_Motivo_Desqualificacao__c FROM Lead WHERE Id IN :ids]) {
      Assert.areEqual('Novo', l.Status, 'T4: CNH B não deveria mudar o Status.');
      Assert.isNull(l.STE_Motivo_Desqualificacao__c, 'T4: CNH B não deveria gravar motivo.');
    }
  }

  @IsTest
  static void t5JaDesqualificadoPreservaMotivo() {
    Lead l = novoSTE('T5', DESQUALIFICADO, null);
    l.STE_Motivo_Desqualificacao__c = MOTIVO_FAIXA;
    insert l;

    Test.startTest();
    update new Lead(Id = l.Id, Tipo_de_CNH__c = CATEGORIA_A);
    Test.stopTest();

    Lead depois = recarregar(l.Id);
    Assert.areEqual(DESQUALIFICADO, depois.Status, 'T5: Status deveria continuar Desqualificado.');
    Assert.areEqual(MOTIVO_FAIXA, depois.STE_Motivo_Desqualificacao__c, 'T5: o motivo original deveria ser preservado.');
  }

  @IsTest
  static void t6ReaberturaManualNaoRedispara() {
    Lead l = novoSTE('T6', 'Novo', null);
    insert l;
    update new Lead(Id = l.Id, Tipo_de_CNH__c = CATEGORIA_A);
    assertDesqualificadoPorA(recarregar(l.Id), 'T6 pré-condição');

    Test.startTest();
    update new Lead(Id = l.Id, Status = 'Em Qualificação');
    update new Lead(Id = l.Id, Company = 'Empresa alterada T6');
    Test.stopTest();

    Lead depois = recarregar(l.Id);
    Assert.areEqual('Em Qualificação', depois.Status, 'T6: reabertura manual deveria ser mantida.');
    Assert.areEqual(CATEGORIA_A, depois.Tipo_de_CNH__c, 'T6: o Tipo deveria continuar Categoria A.');
  }

  @IsTest
  static void t7LeadSolNaoMuda() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
    Lead l = new Lead(
      RecordTypeId = rt('SOL'),
      LastName = 'T7',
      Company = 'Empresa T7',
      Status = 'Novo',
      CNPJ__c = '11222333000181',
      Tipo_de_CNH__c = CATEGORIA_A
    );

    Test.startTest();
    insert l;
    Test.stopTest();

    Lead depois = recarregar(l.Id);
    Assert.areNotEqual(DESQUALIFICADO, depois.Status, 'T7: Lead SOL não deveria ser desqualificado.');
    Assert.isNull(depois.STE_Motivo_Desqualificacao__c, 'T7: Lead SOL não deveria receber motivo STE.');
  }

  @IsTest
  static void t8SaidaDeANaoRequalifica() {
    Lead l = novoSTE('T8', 'Novo', CATEGORIA_A);
    insert l;
    assertDesqualificadoPorA(recarregar(l.Id), 'T8 pré-condição');

    Test.startTest();
    update new Lead(Id = l.Id, Tipo_de_CNH__c = DEFINITIVA);
    Test.stopTest();
    assertDesqualificadoPorA(recarregar(l.Id), 'T8');
  }

  @IsTest
  static void t9Bulk200InsertE200Update() {
    List<Lead> comA = new List<Lead>();
    List<Lead> semTipo = new List<Lead>();
    for (Integer i = 0; i < 200; i++) {
      comA.add(novoSTE('BulkA' + i, 'Novo', CATEGORIA_A));
      semTipo.add(novoSTE('BulkU' + i, 'Novo', null));
    }
    insert semTipo;

    Test.startTest();
    insert comA;
    List<Lead> paraA = new List<Lead>();
    for (Lead l : semTipo) {
      paraA.add(new Lead(Id = l.Id, Tipo_de_CNH__c = CATEGORIA_A));
    }
    update paraA;
    Test.stopTest();

    Set<Id> ids = new Set<Id>();
    for (Lead l : comA) {
      ids.add(l.Id);
    }
    for (Lead l : semTipo) {
      ids.add(l.Id);
    }
    List<Lead> resultado = [SELECT Status, STE_Motivo_Desqualificacao__c FROM Lead WHERE Id IN :ids];
    Assert.areEqual(400, resultado.size(), 'T9: deveria haver 400 Leads.');
    for (Lead l : resultado) {
      assertDesqualificadoPorA(l, 'T9');
    }
  }

  @IsTest
  static void t10ValorDaPicklistTemDoisEspacos() {
    Set<String> valores = new Set<String>();
    for (Schema.PicklistEntry e : Lead.Tipo_de_CNH__c.getDescribe().getPicklistValues()) {
      valores.add(e.getValue());
    }
    Assert.isTrue(valores.contains('CATEGORIA:  A'), 'T10: o valor com dois espaços deveria existir.');
    Assert.isFalse(valores.contains('CATEGORIA: A'), 'T10: o valor com um espaço não deveria existir.');
  }
}

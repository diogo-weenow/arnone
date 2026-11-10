@IsTest
private class STE_NormalizarTelefoneTest {
  @IsTest
  static void leadDeFormularioRecebeOCodigoDoPais() {
    Lead l = new Lead(
      LastName = 'testes normaliza web',
      Company = 'testes normaliza web',
      Email = 'testes.normaliza.web@example.invalid',
      Status = 'Novo',
      MobilePhone = '(11) 98765-4321'
    );

    Test.startTest();
    insert l;
    Test.stopTest();

    Assert.areEqual(
      '5511987654321',
      [SELECT STE_Telefone_E164__c FROM Lead WHERE Id = :l.Id]
      .STE_Telefone_E164__c,
      'Telefone digitado em formulário precisa virar a mesma chave do WhatsApp.'
    );
  }

  @IsTest
  static void usaOPhoneQuandoNaoHaMobilePhone() {
    Lead l = new Lead(
      LastName = 'testes normaliza fixo',
      Company = 'testes normaliza fixo',
      Email = 'testes.normaliza.fixo@example.invalid',
      Status = 'Novo',
      Phone = '+55 16 3333-4444'
    );

    Test.startTest();
    insert l;
    Test.stopTest();

    Assert.areEqual(
      '551633334444',
      [SELECT STE_Telefone_E164__c FROM Lead WHERE Id = :l.Id]
      .STE_Telefone_E164__c
    );
  }

  @IsTest
  static void naoTrocaAIdentidadeJaGravada() {
    Lead l = new Lead(
      LastName = 'testes normaliza preservado',
      Company = 'testes normaliza preservado',
      Email = 'testes.normaliza.preservado@example.invalid',
      Status = 'Novo',
      MobilePhone = '(11) 3333-4444',
      STE_Telefone_E164__c = '5511999998888'
    );

    Test.startTest();
    insert l;
    Test.stopTest();

    Assert.areEqual(
      '5511999998888',
      [SELECT STE_Telefone_E164__c FROM Lead WHERE Id = :l.Id]
      .STE_Telefone_E164__c,
      'O telefone do WhatsApp gravado pelo bot não pode ser sobrescrito.'
    );
  }

  @IsTest
  static void preencheNaAtualizacaoQuandoOTelefoneChega() {
    Lead l = new Lead(
      LastName = 'testes normaliza depois',
      Company = 'testes normaliza depois',
      Email = 'testes.normaliza.depois@example.invalid',
      Status = 'Novo'
    );
    insert l;
    Assert.isNull(
      [SELECT STE_Telefone_E164__c FROM Lead WHERE Id = :l.Id]
      .STE_Telefone_E164__c
    );

    Test.startTest();
    update new Lead(Id = l.Id, MobilePhone = '11 91234-5678');
    Test.stopTest();

    Assert.areEqual(
      '5511912345678',
      [SELECT STE_Telefone_E164__c FROM Lead WHERE Id = :l.Id]
      .STE_Telefone_E164__c
    );
  }

  @IsTest
  static void ignoraTelefoneCurtoOuAusente() {
    Lead semTelefone = new Lead(
      LastName = 'testes normaliza sem',
      Company = 'testes normaliza sem',
      Email = 'testes.normaliza.sem@example.invalid',
      Status = 'Novo'
    );
    Lead curto = new Lead(
      LastName = 'testes normaliza curto',
      Company = 'testes normaliza curto',
      Email = 'testes.normaliza.curto@example.invalid',
      Status = 'Novo',
      Phone = '3333-4444'
    );

    Test.startTest();
    insert new List<Lead>{ semTelefone, curto };
    Test.stopTest();

    for (Lead l : [
      SELECT STE_Telefone_E164__c
      FROM Lead
      WHERE Id IN :new List<Id>{ semTelefone.Id, curto.Id }
    ]) {
      Assert.isNull(
        l.STE_Telefone_E164__c,
        'Sem DDD não há como identificar: melhor deixar vazio.'
      );
    }
  }

  @IsTest
  static void contatoTambemEhNormalizado() {
    Contact c = new Contact(
      LastName = 'testes normaliza contato',
      Email = 'testes.normaliza.contato@example.invalid',
      MobilePhone = '+55 (11) 98888-7777'
    );

    Test.startTest();
    insert c;
    Test.stopTest();

    Assert.areEqual(
      '5511988887777',
      [SELECT STE_Telefone_E164__c FROM Contact WHERE Id = :c.Id]
      .STE_Telefone_E164__c
    );
  }

  @IsTest
  static void aceitaListaNula() {
    STE_NormalizarTelefone.aplicar(null);
    STE_NormalizarTelefone.aplicar(new List<Lead>());
  }
}
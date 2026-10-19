/**
 * Cobertura do backfill single -> multi de produto (Lead e Opportunity),
 * incluindo idempotência e não-sobrescrita do campo novo já preenchido.
 */
@IsTest
private class SOLProdutoBackfillBatchTest {
  private static Id rtLead() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Id rtOpp() {
    return Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  @IsTest
  static void migraLeadSingleParaMulti() {
    Lead l = new Lead(
      RecordTypeId = rtLead(),
      LastName = 'Backfill',
      Company = 'Empresa Backfill',
      Status = 'Recebido - MQL',
      Unidade_Origem__c = 'SOL',
      CNPJ__c = '11.222.333/0001-81',
      SOL_Produto_Interesse__c = 'ART 360'
    );
    insert l;
    // Garante o novo vazio no ponto de partida.
    update new Lead(Id = l.Id, SOL_Produtos_Interesse__c = null);

    Test.startTest();
    Database.executeBatch(new SOLProdutoBackfillBatch('Lead'), 200);
    Test.stopTest();

    Lead depois = [
      SELECT SOL_Produto_Interesse__c, SOL_Produtos_Interesse__c
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.areEqual(
      'ART 360',
      depois.SOL_Produtos_Interesse__c,
      'O valor single foi copiado para o multi.'
    );
    Assert.areEqual(
      'ART 360',
      depois.SOL_Produto_Interesse__c,
      'O campo antigo permanece intacto (não é apagado).'
    );
  }

  @IsTest
  static void migraOpportunitySingleParaMulti() {
    Account a = new Account(Name = 'Conta Backfill');
    insert a;
    Opportunity o = new Opportunity(
      RecordTypeId = rtOpp(),
      Name = 'Opp Backfill',
      AccountId = a.Id,
      StageName = 'Oportunidade Criada',
      CloseDate = Date.today().addDays(30),
      SOL_Produto_Negocio__c = 'Recuperação Tributária'
    );
    insert o;
    update new Opportunity(Id = o.Id, SOL_Produtos_Negocio__c = null);

    Test.startTest();
    Database.executeBatch(new SOLProdutoBackfillBatch('Opportunity'), 200);
    Test.stopTest();

    Opportunity depois = [
      SELECT SOL_Produtos_Negocio__c
      FROM Opportunity
      WHERE Id = :o.Id
    ];
    Assert.areEqual(
      'Recuperação Tributária',
      depois.SOL_Produtos_Negocio__c,
      'O valor single foi copiado para o multi na Oportunidade.'
    );
  }

  @IsTest
  static void idempotenteNaoSobrescreveNovoJaPreenchido() {
    Lead l = new Lead(
      RecordTypeId = rtLead(),
      LastName = 'Idem',
      Company = 'Empresa Idem',
      Status = 'Recebido - MQL',
      Unidade_Origem__c = 'SOL',
      CNPJ__c = '11.222.333/0002-81',
      SOL_Produto_Interesse__c = 'ART 360',
      // Novo já tem seleção MÚLTIPLA, feita após eventual migração anterior.
      SOL_Produtos_Interesse__c = 'ART 360;Revisão trabalhista'
    );
    insert l;

    Test.startTest();
    // Reexecução do backfill não deve tocar quem já tem o novo preenchido.
    Database.executeBatch(new SOLProdutoBackfillBatch('Lead'), 200);
    Test.stopTest();

    Lead depois = [
      SELECT SOL_Produtos_Interesse__c FROM Lead WHERE Id = :l.Id
    ];
    Assert.areEqual(
      'ART 360;Revisão trabalhista',
      depois.SOL_Produtos_Interesse__c,
      'Backfill é idempotente: não sobrescreve seleção múltipla existente.'
    );
  }

  @IsTest
  static void objetoNaoSuportadoFalha() {
    Boolean falhou = false;
    try {
      new SOLProdutoBackfillBatch('Contact');
    } catch (SOLProdutoBackfillBatch.BackfillException e) {
      falhou = true;
    }
    Assert.isTrue(falhou, 'Objeto fora de Lead/Opportunity é rejeitado.');
  }
}

/**
 * Importação de leads — testes do backfill de Lead.CNPJ_Normalizado__c (25) e do
 * Flow before-save que normaliza em maiúsculas (3).
 */
@IsTest
private class CnpjNormalizadoBackfillBatchTest {
  @IsTest
  static void backfillPreencheNormalizadoFaltante() {
    // Lead sem RT SOL com CNPJ. O Flow preenche na inserção; simulamos um lead
    // antigo limpando o campo sem mexer no CNPJ (o Flow não reprocessa).
    Lead numerico = new Lead(LastName = 'Antigo', Company = 'Empresa Antiga', CNPJ__c = '11.222.333/0001-81');
    Lead alfa = new Lead(LastName = 'Antigo Alfa', Company = 'Empresa Alfa', CNPJ__c = '12.abc.345/01de-35');
    insert new List<Lead>{ numerico, alfa };
    update new List<Lead>{
      new Lead(Id = numerico.Id, CNPJ_Normalizado__c = null),
      new Lead(Id = alfa.Id, CNPJ_Normalizado__c = 'valor antigo')
    };
    Assert.isNull(
      [SELECT CNPJ_Normalizado__c FROM Lead WHERE Id = :numerico.Id].CNPJ_Normalizado__c,
      'Pré-condição: normalizado vazio.'
    );

    Test.startTest();
    Database.executeBatch(new CnpjNormalizadoBackfillBatch(), 200);
    Test.stopTest();

    Assert.areEqual(
      '11222333000181',
      [SELECT CNPJ_Normalizado__c FROM Lead WHERE Id = :numerico.Id].CNPJ_Normalizado__c,
      'Backfill preenche o CNPJ normalizado.'
    );
    Assert.isTrue(
      [SELECT CNPJ_Normalizado__c FROM Lead WHERE Id = :alfa.Id]
        .CNPJ_Normalizado__c.equals('12ABC34501DE35'),
      'Backfill corrige para maiúsculas.'
    );
  }

  @IsTest
  static void flowGravaNormalizadoEmMaiusculas() {
    Lead l = new Lead(LastName = 'Alfa Min', Company = 'Emp Alfa Min', CNPJ__c = '12.abc.345/01de-35');
    Test.startTest();
    insert l;
    Test.stopTest();
    String norm = [SELECT CNPJ_Normalizado__c FROM Lead WHERE Id = :l.Id].CNPJ_Normalizado__c;
    // equals: o == do Apex não diferencia maiúsculas.
    Assert.isTrue('12ABC34501DE35'.equals(norm), 'Flow grava em maiúsculas: ' + norm);
  }

  @IsTest
  static void normalizacaoIgualAoFlow() {
    Assert.isTrue(
      CnpjNormalizadoBackfillBatch.normalizarComoFlow(' 12.abc.345/01de-35 ').equals('12ABC34501DE35'),
      'Mesma regra do Flow.'
    );
    Assert.areEqual('', CnpjNormalizadoBackfillBatch.normalizarComoFlow(null), 'Vazio para nulo.');
  }
}

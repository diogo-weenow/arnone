/**
 * Upload enriquecimento Lemit — teste do backfill único de
 * Lead.SOL_CNPJ_Normalizado__c.
 */
@IsTest
private class SOLCnpjBackfillBatchTest {
  @IsTest
  static void backfillPreencheNormalizadoFaltante() {
    // Lead simples (sem RT SOL) com CNPJ. O Flow before-save preenche o
    // normalizado na inserção; simulamos um Lead "antigo" limpando o campo sem
    // mexer no CNPJ (o Flow não reprocessa, pois o CNPJ não muda).
    Lead l = new Lead(
      LastName = 'Antigo',
      Company = 'Empresa Antiga',
      CNPJ__c = '11.222.333/0001-81'
    );
    insert l;
    update new Lead(Id = l.Id, SOL_CNPJ_Normalizado__c = null);

    Assert.areEqual(
      null,
      [SELECT SOL_CNPJ_Normalizado__c FROM Lead WHERE Id = :l.Id]
        .SOL_CNPJ_Normalizado__c,
      'Pré-condição: normalizado deveria estar vazio.'
    );

    Test.startTest();
    Database.executeBatch(new SOLCnpjBackfillBatch(), 200);
    Test.stopTest();

    Assert.areEqual(
      '11222333000181',
      [SELECT SOL_CNPJ_Normalizado__c FROM Lead WHERE Id = :l.Id]
        .SOL_CNPJ_Normalizado__c,
      'O backfill deveria preencher o CNPJ normalizado.'
    );
  }

  @IsTest
  static void utilNormalizaEFormata() {
    Assert.areEqual(
      '11222333000181',
      SOLEnriquecimentoUtil.normalizarCnpj('11.222.333/0001-81'),
      'Normalização deveria remover a pontuação.'
    );
    Assert.isTrue(
      SOLEnriquecimentoUtil.cnpjValido('11222333000181'),
      '14 dígitos deveria ser válido.'
    );
    Assert.isFalse(
      SOLEnriquecimentoUtil.cnpjValido('123'),
      'Menos de 14 dígitos é inválido.'
    );
    Assert.areEqual(
      '11.222.333/0001-81',
      SOLEnriquecimentoUtil.formatarCnpj('11222333000181'),
      'Formatação deveria aplicar a máscara.'
    );
  }
}

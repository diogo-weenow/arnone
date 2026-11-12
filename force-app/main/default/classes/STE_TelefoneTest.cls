@IsTest
private class STE_TelefoneTest {
  @IsTest
  static void digitosRemovePontuacao() {
    Assert.areEqual('5511987654321', STE_Telefone.digitos('+55 (11) 98765-4321'));
    Assert.isNull(STE_Telefone.digitos(null));
    Assert.isNull(STE_Telefone.digitos('   '));
    Assert.isNull(STE_Telefone.digitos('sem numero'));
  }

  @IsTest
  static void chaveExigeTamanhoMinimo() {
    Assert.areEqual('5511987654321', STE_Telefone.chave('+5511987654321'));
    Assert.isNull(STE_Telefone.chave('98765432'), 'Oito dígitos não identificam.');
    Assert.isNull(STE_Telefone.chave('123'));
  }

  @IsTest
  static void chaveCompletaOCodigoDoPaisEmNumeroLocal() {
    Assert.areEqual(
      '5511987654321',
      STE_Telefone.chave('(11) 98765-4321'),
      'Onze dígitos são DDD + celular: precisa ganhar o 55.'
    );
    Assert.areEqual(
      '551198765432',
      STE_Telefone.chave('11 9876-5432'),
      'Dez dígitos são DDD + fixo: também ganham o 55.'
    );
    Assert.areEqual(
      '5511987654321',
      STE_Telefone.chave('5511987654321'),
      'Quem já tem código do país não recebe outro.'
    );
  }

  @IsTest
  static void variantesCobremONonoDigito() {
    Set<String> comNove = STE_Telefone.variantes('+55 (11) 98765-4321');
    Assert.areEqual(2, comNove.size());
    Assert.isTrue(comNove.contains('5511987654321'));
    Assert.isTrue(
      comNove.contains('551187654321'),
      'Precisa gerar a forma antiga, de 8 dígitos.'
    );

    Set<String> semNove = STE_Telefone.variantes('551187654321');
    Assert.areEqual(2, semNove.size());
    Assert.isTrue(semNove.contains('5511987654321'));
  }

  @IsTest
  static void variantesIgnoramValorInvalido() {
    Assert.areEqual(0, STE_Telefone.variantes(null).size());
    Assert.areEqual(0, STE_Telefone.variantes('123').size());
    Assert.areEqual(0, STE_Telefone.variantes('  ').size());
  }

  @IsTest
  static void variantesNaoDuplicamCelularSemPadraoBrasileiro() {
    // 13 dígitos começando com 55, mas o quinto dígito não é 9: sem variante.
    Set<String> unico = STE_Telefone.variantes('5511387654321');
    Assert.areEqual(1, unico.size());
  }
}
/**
 * Importação de leads — testes das funções puras de documento (CNPJ numérico e
 * alfanumérico, CPF, formatos e notação científica). Cenários 1 a 5.
 */
@IsTest
private class ImportacaoLeadsDocumentoTest {
  @IsTest
  static void cnpjCom13DigitosEhCompletadoEValido() {
    String norm = ImportacaoLeadsDocumento.normalizarCnpj('1234567000195');
    Assert.areEqual('01234567000195', norm, 'CNPJ de 13 dígitos deveria ganhar o zero à esquerda.');
    Assert.isTrue(ImportacaoLeadsDocumento.cnpjValido(norm), 'CNPJ completado tem DV válido.');
    Assert.areEqual(
      '00123456000149',
      ImportacaoLeadsDocumento.normalizarCnpj('123456000149'),
      'CNPJ de 12 dígitos deveria ganhar dois zeros.'
    );
    Assert.isNull(
      ImportacaoLeadsDocumento.motivoInvalido('1234567000195', 'CNPJ'),
      'Chave de 13 dígitos com DV válido não tem motivo de invalidade.'
    );
  }

  @IsTest
  static void cnpjComDvInvalido() {
    Assert.isFalse(ImportacaoLeadsDocumento.cnpjValido('11222333000182'), 'DV trocado é inválido.');
    Assert.areEqual(
      'DV_INVALIDO',
      ImportacaoLeadsDocumento.motivoInvalido('11.222.333/0001-82', 'CNPJ'),
      'Motivo deveria ser DV_INVALIDO.'
    );
    Assert.areEqual(
      'TAMANHO_INVALIDO',
      ImportacaoLeadsDocumento.motivoInvalido('123', 'CNPJ'),
      'CNPJ curto é TAMANHO_INVALIDO.'
    );
    Assert.areEqual(
      'TAMANHO_INVALIDO',
      ImportacaoLeadsDocumento.motivoInvalido('11222333000#81', 'CNPJ'),
      'Caractere fora de [0-9A-Z] é TAMANHO_INVALIDO.'
    );
    Assert.areEqual(
      'CHAVE_AUSENTE',
      ImportacaoLeadsDocumento.motivoInvalido('  ', 'CNPJ'),
      'Célula vazia é CHAVE_AUSENTE.'
    );
  }

  @IsTest
  static void cnpjAlfanumericoMaiusculasEMinusculasSaoIguais() {
    // Exemplo oficial da Receita: 12.ABC.345/01DE-35.
    Assert.areEqual('35', ImportacaoLeadsDocumento.dvCnpj('12ABC34501DE'), 'DV do exemplo oficial é 35.');
    String maiusc = ImportacaoLeadsDocumento.normalizarCnpj('12.ABC.345/01DE-35');
    String minusc = ImportacaoLeadsDocumento.normalizarCnpj('12.abc.345/01de-35');
    Assert.isTrue(maiusc.equals(minusc), 'Maiúsculas e minúsculas normalizam igual.');
    Assert.isTrue(maiusc.equals('12ABC34501DE35'), 'Normalizado fica em maiúsculas.');
    Assert.isTrue(ImportacaoLeadsDocumento.cnpjValido(maiusc), 'CNPJ alfanumérico oficial é válido.');
    Assert.areEqual(
      '12.ABC.345/01DE-35',
      ImportacaoLeadsDocumento.formatarCnpj(maiusc),
      'Máscara aplicada ao alfanumérico.'
    );
    Assert.isFalse(
      ImportacaoLeadsDocumento.cnpjValido('12ABC34501DEAB'),
      'DV com letra é inválido (os 2 últimos são numéricos).'
    );
  }

  @IsTest
  static void notacaoCientificaEhDetectada() {
    Assert.isTrue(ImportacaoLeadsDocumento.ehNotacaoCientifica('4,53413E+13'), 'Vírgula decimal.');
    Assert.isTrue(ImportacaoLeadsDocumento.ehNotacaoCientifica('1.58656e13'), 'Ponto decimal, e minúsculo.');
    Assert.isFalse(ImportacaoLeadsDocumento.ehNotacaoCientifica('11222333000181'), 'Número comum não é notação.');
    Assert.isFalse(ImportacaoLeadsDocumento.ehNotacaoCientifica('12ABC34501DE35'), 'Alfanumérico não é notação.');
    Assert.areEqual(
      'NOTACAO_CIENTIFICA',
      ImportacaoLeadsDocumento.motivoInvalido('4,53413E+13', 'CNPJ'),
      'CNPJ em notação científica.'
    );
    Assert.areEqual(
      'NOTACAO_CIENTIFICA',
      ImportacaoLeadsDocumento.motivoInvalido('1,23457E+10', 'CPF'),
      'CPF em notação científica (testado antes de limpar os dígitos).'
    );
  }

  @IsTest
  static void cpfCompletadoValidadoEFormatos() {
    String norm = ImportacaoLeadsDocumento.normalizarCpf('1234567890');
    Assert.areEqual('01234567890', norm, 'CPF de 10 dígitos ganha o zero à esquerda.');
    Assert.isTrue(ImportacaoLeadsDocumento.cpfValido(norm), 'CPF completado tem DV válido.');
    Assert.isTrue(ImportacaoLeadsDocumento.cpfValido('12345678909'), 'CPF de referência é válido.');
    Assert.isFalse(ImportacaoLeadsDocumento.cpfValido('12345678900'), 'DV errado é inválido.');
    Assert.areEqual(
      'DV_INVALIDO',
      ImportacaoLeadsDocumento.motivoInvalido('123.456.789-00', 'CPF'),
      'Motivo DV_INVALIDO para CPF.'
    );
    Assert.areEqual(
      'TAMANHO_INVALIDO',
      ImportacaoLeadsDocumento.motivoInvalido('123456789012', 'CPF'),
      'CPF com 12 dígitos é TAMANHO_INVALIDO.'
    );
    Assert.areEqual(
      '12345678909',
      ImportacaoLeadsDocumento.normalizarCpf('123.456.789-09'),
      'Máscara removida.'
    );
    List<String> formatos = ImportacaoLeadsDocumento.formatosCpf('12345678909');
    Assert.areEqual(2, formatos.size(), 'Dois formatos de busca.');
    Assert.isTrue(formatos.contains('12345678909'), 'Formato só dígitos.');
    Assert.isTrue(formatos.contains('123.456.789-09'), 'Formato mascarado.');
  }
}

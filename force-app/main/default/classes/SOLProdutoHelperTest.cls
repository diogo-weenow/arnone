/**
 * Cobertura do helper de produto multi-valor da Arnone Soluções.
 * Cobre split de 1/2/3 produtos, ordem indiferente, string vazia -> vazio,
 * contém/contémAlgum e a emissão de produtos para evento (incl. vazio -> [null]).
 */
@IsTest
private class SOLProdutoHelperTest {
  private static final String RT = SOLProdutoHelper.PRODUTO_RECUPERACAO;
  private static final String ART = SOLProdutoHelper.PRODUTO_ART;
  private static final String REV = SOLProdutoHelper.PRODUTO_REVISAO;

  @IsTest
  static void valoresSeparaUmDoisTresProdutos() {
    Assert.areEqual(
      new Set<String>{ RT },
      SOLProdutoHelper.valores(RT),
      'Um produto vira conjunto de um.'
    );
    Assert.areEqual(
      new Set<String>{ RT, ART },
      SOLProdutoHelper.valores(RT + ';' + ART),
      'Dois produtos.'
    );
    Assert.areEqual(
      new Set<String>{ RT, ART, REV },
      SOLProdutoHelper.valores(ART + ';' + REV + ';' + RT),
      'Três produtos, ordem indiferente.'
    );
  }

  @IsTest
  static void valoresTrataVazioEEspacos() {
    Assert.isTrue(
      SOLProdutoHelper.valores(null).isEmpty(),
      'Null -> conjunto vazio.'
    );
    Assert.isTrue(
      SOLProdutoHelper.valores('').isEmpty(),
      'String vazia -> conjunto vazio.'
    );
    Assert.isTrue(
      SOLProdutoHelper.valores('   ').isEmpty(),
      'Só espaços -> conjunto vazio.'
    );
    Assert.areEqual(
      new Set<String>{ RT, ART },
      SOLProdutoHelper.valores(RT + '; ' + ART + ';'),
      'Espaços e separador final são limpos, sem vazios no conjunto.'
    );
  }

  @IsTest
  static void contemIdentificaProdutoNoMulti() {
    Assert.isTrue(SOLProdutoHelper.contem(RT, RT), 'Seleção única contém.');
    Assert.isTrue(
      SOLProdutoHelper.contem(ART + ';' + REV, REV),
      'Multi contém Revisão.'
    );
    Assert.isFalse(
      SOLProdutoHelper.contem(ART + ';' + REV, RT),
      'Multi sem RT não contém RT.'
    );
    Assert.isFalse(SOLProdutoHelper.contem(null, RT), 'Null não contém.');
    Assert.isFalse(SOLProdutoHelper.contem(RT, null), 'Produto nulo é falso.');
  }

  @IsTest
  static void contemAlgumUniaoDoMaisExigente() {
    Assert.isTrue(
      SOLProdutoHelper.contemAlgum(REV, SOLProdutoHelper.PRODUTOS_SOL),
      'Revisão está entre os três.'
    );
    Assert.isTrue(
      SOLProdutoHelper.contemAlgum(
        ART + ';' + REV,
        new Set<String>{ RT, ART }
      ),
      'ART no conjunto casa mesmo misturado com Revisão.'
    );
    Assert.isFalse(
      SOLProdutoHelper.contemAlgum(REV, new Set<String>{ RT, ART }),
      'Revisão sozinha não casa com {RT, ART}.'
    );
    Assert.isFalse(
      SOLProdutoHelper.contemAlgum(RT, null),
      'Conjunto nulo é falso.'
    );
    Assert.isFalse(
      SOLProdutoHelper.contemAlgum(RT, new Set<String>()),
      'Conjunto vazio é falso.'
    );
  }

  @IsTest
  static void paraEventosUmPorProdutoEVazioViraNull() {
    Assert.areEqual(
      1,
      SOLProdutoHelper.paraEventos(RT).size(),
      'Um produto -> um evento.'
    );
    Assert.areEqual(
      2,
      SOLProdutoHelper.paraEventos(RT + ';' + ART).size(),
      'Dois produtos -> dois eventos.'
    );
    List<String> vazio = SOLProdutoHelper.paraEventos(null);
    Assert.areEqual(1, vazio.size(), 'Vazio ainda gera uma ocorrência.');
    Assert.areEqual(null, vazio[0], 'Produto do evento vazio é null.');
  }

  @IsTest
  static void paraRotuloTrocaSeparador() {
    Assert.areEqual(
      RT + ', ' + ART,
      SOLProdutoHelper.paraRotulo(RT + ';' + ART),
      'Separador vira vírgula e espaço.'
    );
    Assert.areEqual(RT, SOLProdutoHelper.paraRotulo(RT), 'Único não muda.');
    Assert.areEqual(null, SOLProdutoHelper.paraRotulo(null), 'Null continua null.');
  }
}

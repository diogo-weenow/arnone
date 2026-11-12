@IsTest
private class STE_ParametrosMensagemTest {
  private static STE_ParametrosMensagem.Entrada entrada(String nome, String pendencia) {
    STE_ParametrosMensagem.Entrada e = new STE_ParametrosMensagem.Entrada();
    e.nomeCandidato = nome;
    e.pendencia = pendencia;
    return e;
  }

  @IsTest
  static void montaApenasONomeQuandoNaoHaPendencia() {
    List<STE_ParametrosMensagem.Saida> saidas = STE_ParametrosMensagem.montar(
      new List<STE_ParametrosMensagem.Entrada>{ entrada('Maria', null) }
    );

    Assert.areEqual(1, saidas[0].parametros.size(), 'só o nome deveria virar parâmetro');
    Assert.areEqual('Nome_do_candidato', saidas[0].parametros[0].parameterName);
    Assert.areEqual('Maria', saidas[0].parametros[0].textValue);
  }

  @IsTest
  static void montaNomeEPendenciaNaOrdemDoTemplate() {
    List<STE_ParametrosMensagem.Saida> saidas = STE_ParametrosMensagem.montar(
      new List<STE_ParametrosMensagem.Entrada>{ entrada('João', 'foto da CNH') }
    );

    Assert.areEqual(2, saidas[0].parametros.size());
    Assert.areEqual('Nome_do_candidato', saidas[0].parametros[0].parameterName, 'o nome é {{1}}');
    Assert.areEqual('Pendencia', saidas[0].parametros[1].parameterName, 'a pendência é {{2}}');
    Assert.areEqual('foto da CNH', saidas[0].parametros[1].textValue);
  }

  @IsTest
  static void ignoraValorEmBranco() {
    List<STE_ParametrosMensagem.Saida> saidas = STE_ParametrosMensagem.montar(
      new List<STE_ParametrosMensagem.Entrada>{ entrada('   ', '') }
    );

    Assert.areEqual(0, saidas[0].parametros.size(), 'branco não vira parâmetro');
  }

  @IsTest
  static void respondeUmaSaidaPorEntrada() {
    List<STE_ParametrosMensagem.Saida> saidas = STE_ParametrosMensagem.montar(
      new List<STE_ParametrosMensagem.Entrada>{
        entrada('Ana', null),
        entrada('Bruno', 'comprovante de residência')
      }
    );

    Assert.areEqual(2, saidas.size());
    Assert.areEqual(1, saidas[0].parametros.size());
    Assert.areEqual(2, saidas[1].parametros.size());
  }
}
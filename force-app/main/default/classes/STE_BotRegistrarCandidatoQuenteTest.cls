@IsTest
private class STE_BotRegistrarCandidatoQuenteTest {
  @IsTest
  static void registraLeadQuenteSemDependerDeVariavelDoBot() {
    STE_BotRegistrarCandidatoQuente.Entrada entrada = new STE_BotRegistrarCandidatoQuente.Entrada();
    entrada.email = 'testes.bot.upload.quente@example.invalid';
    entrada.nomeCompleto = 'testes bot upload quente';
    entrada.respostaPreInscricao = 'Sim, vamos la!';
    entrada.respostaIdade = 'Sim';
    entrada.jaTrabalhouTelecom = 'Sim';
    entrada.empresaTelecomAnterior = 'testes Empresa Telecom Quente';
    entrada.routableId = '0Mw000000000001';

    Test.startTest();
    List<STE_BotRegistrarCandidatoQuente.Resultado> resultados = STE_BotRegistrarCandidatoQuente.registrar(
      new List<STE_BotRegistrarCandidatoQuente.Entrada>{ entrada }
    );
    Test.stopTest();

    Assert.areEqual(1, resultados.size());
    Assert.isTrue(resultados[0].sucesso, resultados[0].mensagem);
    Lead leadCriado = [
      SELECT
        Id,
        STE_Classificacao_Fila__c,
        STE_Possui_CNH__c,
        STE_CNH_Enviada__c,
        STE_Ja_Trabalhou_Telecom__c,
        STE_Empresa_Telecom_Anterior__c,
        STE_MessagingSession_Id__c
      FROM Lead
      WHERE Id = :resultados[0].recordId
    ];
    Assert.areEqual('Quente', leadCriado.STE_Classificacao_Fila__c);
    Assert.areEqual('Sim, envio imediato', leadCriado.STE_Possui_CNH__c);
    Assert.areEqual('Sim', leadCriado.STE_Ja_Trabalhou_Telecom__c);
    Assert.areEqual(
      'testes Empresa Telecom Quente',
      leadCriado.STE_Empresa_Telecom_Anterior__c
    );
    Assert.isFalse(leadCriado.STE_CNH_Enviada__c);
    Assert.isTrue(
      leadCriado.STE_MessagingSession_Id__c.startsWith('0Mw000000000001'),
      'O ID da sessao deve ser preservado, aceitando a normalizacao de 15 para 18 caracteres.'
    );
  }

  @IsTest
  static void preservaValidacaoDeEmailObrigatorio() {
    STE_BotRegistrarCandidatoQuente.Entrada entrada = new STE_BotRegistrarCandidatoQuente.Entrada();
    entrada.nomeCompleto = 'testes sem email';
    entrada.respostaIdade = 'Sim';

    List<STE_BotRegistrarCandidatoQuente.Resultado> resultados = STE_BotRegistrarCandidatoQuente.registrar(
      new List<STE_BotRegistrarCandidatoQuente.Entrada>{ entrada }
    );

    Assert.areEqual(1, resultados.size());
    Assert.isFalse(resultados[0].sucesso);
    Assert.isTrue(resultados[0].mensagem.contains('e-mail'));
  }
}
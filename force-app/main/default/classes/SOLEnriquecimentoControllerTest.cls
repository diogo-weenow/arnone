/**
 * Upload enriquecimento Lemit — testes da camada de orquestração.
 *
 * Classificação por balde (match único, múltiplo, convertido, inválido,
 * duplicado no arquivo), guardas de entrada, configuração e o caminho
 * confirmar/consultar. O processamento efetivo é coberto por
 * SOLEnriquecimentoBatchTest.
 */
@IsTest
private class SOLEnriquecimentoControllerTest {
  private static final String CNPJ_A = '11222333000181';
  private static final String CNPJ_B = '11444777000161';

  @TestSetup
  static void semear() {
    SOLEnriquecimentoTestFactory.atribuirPsAoUsuarioAtual();
    SOLEnriquecimentoTestFactory.semearSingleton();
  }

  private static SOLEnriquecimentoController.LinhaDTO dto(
    Integer n,
    String cnpj,
    Map<String, String> v
  ) {
    SOLEnriquecimentoController.LinhaDTO d = new SOLEnriquecimentoController.LinhaDTO();
    d.numeroLinha = n;
    d.cnpj = cnpj;
    d.valores = v;
    return d;
  }

  // Espelha a LWC: as linhas viajam como string JSON (ver adicionarLinhas).
  private static void adicionar(
    Id loteId,
    List<SOLEnriquecimentoController.LinhaDTO> linhas
  ) {
    SOLEnriquecimentoController.adicionarLinhas(loteId, JSON.serialize(linhas));
  }

  private static Map<String, String> valoresPadrao(String funcionarios) {
    return new Map<String, String>{
      'NumberOfEmployees' => funcionarios,
      'Company' => 'Empresa Lemit',
      'LastName' => 'Contato Lemit'
    };
  }

  private static SOL_Enriquecimento_Linha__c linhaDo(Id loteId) {
    return [
      SELECT Resultado_Match__c, Acao__c, Leads_Alvo__c
      FROM SOL_Enriquecimento_Linha__c
      WHERE Lote__c = :loteId
      LIMIT 1
    ];
  }

  @IsTest
  static void matchUnicoAtualizaSoEle() {
    SOLEnriquecimentoTestFactory.montarFila(2);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    Lead a = SOLEnriquecimentoTestFactory.novoLeadSOL('A', 'Emp A', CNPJ_A);

    Id lote = SOLEnriquecimentoController.iniciarLote('f.csv', 1);
    adicionar(
      lote,
      new List<SOLEnriquecimentoController.LinhaDTO>{
        dto(1, '11.222.333/0001-81', valoresPadrao('500'))
      }
    );

    Test.startTest();
    SOLEnriquecimentoController.PreviewDTO pv = SOLEnriquecimentoController.classificar(
      lote
    );
    Test.stopTest();

    Assert.areEqual(1, pv.matchUnico, 'Deve classificar 1 match único.');
    Assert.areEqual(0, pv.semMatch, 'Não há criação neste caso.');
    SOL_Enriquecimento_Linha__c l = linhaDo(lote);
    Assert.areEqual('MATCH_UNICO', l.Resultado_Match__c, 'Balde errado.');
    Assert.areEqual('ATUALIZAR', l.Acao__c, 'Ação deveria ser ATUALIZAR.');
    Assert.isTrue(
      l.Leads_Alvo__c.contains(a.Id),
      'O Lead casado deveria estar nos alvos.'
    );
  }

  @IsTest
  static void matchMultiploListaCandidatos() {
    SOLEnriquecimentoTestFactory.montarFila(2);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    SOLEnriquecimentoTestFactory.novoLeadSOL('A1', 'Emp A1', CNPJ_A);
    SOLEnriquecimentoTestFactory.novoLeadSOL('A2', 'Emp A2', CNPJ_A);

    Id lote = SOLEnriquecimentoController.iniciarLote('f.csv', 1);
    adicionar(
      lote,
      new List<SOLEnriquecimentoController.LinhaDTO>{
        dto(1, CNPJ_A, valoresPadrao('500'))
      }
    );

    Test.startTest();
    SOLEnriquecimentoController.PreviewDTO pv = SOLEnriquecimentoController.classificar(
      lote
    );
    Test.stopTest();

    Assert.areEqual(1, pv.matchMultiplo, 'Deve haver 1 match múltiplo.');
    Assert.areEqual(1, pv.multiplos.size(), 'Deve devolver a linha múltipla.');
    Assert.areEqual(
      2,
      pv.multiplos[0].leadsAlvo.size(),
      'Dois candidatos para seleção.'
    );
    SOL_Enriquecimento_Linha__c l = linhaDo(lote);
    Assert.areEqual('MATCH_MULTIPLO', l.Resultado_Match__c, 'Balde errado.');
  }

  @IsTest
  static void convertidoEhIgnorado() {
    SOLEnriquecimentoTestFactory.montarFila(2);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    Lead c = SOLEnriquecimentoTestFactory.novoLeadSOL('Conv', 'Emp C', CNPJ_A);

    // Passa a VR de conversão e converte.
    update new Lead(Id = c.Id, SOL_Status_Procuracao__c = 'Recebida');
    String convStatus = [
      SELECT MasterLabel
      FROM LeadStatus
      WHERE IsConverted = TRUE
      LIMIT 1
    ]
    .MasterLabel;
    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(c.Id);
    lc.setConvertedStatus(convStatus);
    lc.setDoNotCreateOpportunity(true);
    Database.convertLead(lc);

    Id lote = SOLEnriquecimentoController.iniciarLote('f.csv', 1);
    adicionar(
      lote,
      new List<SOLEnriquecimentoController.LinhaDTO>{
        dto(1, CNPJ_A, valoresPadrao('900'))
      }
    );

    Test.startTest();
    SOLEnriquecimentoController.PreviewDTO pv = SOLEnriquecimentoController.classificar(
      lote
    );
    Test.stopTest();

    Assert.areEqual(1, pv.convertido, 'Deve cair no balde CONVERTIDO.');
    Assert.areEqual(0, pv.semMatch, 'Convertido não vira criação.');
    SOL_Enriquecimento_Linha__c l = linhaDo(lote);
    Assert.areEqual('CONVERTIDO', l.Resultado_Match__c, 'Balde errado.');
    Assert.areEqual('IGNORAR', l.Acao__c, 'Convertido não atualiza.');
  }

  @IsTest
  static void invalidoPorCnpjEPorFaltaDeCompany() {
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    Id lote = SOLEnriquecimentoController.iniciarLote('f.csv', 2);
    adicionar(
      lote,
      new List<SOLEnriquecimentoController.LinhaDTO>{
        dto(1, '123', valoresPadrao('100')), // CNPJ curto
        dto(
          2,
          CNPJ_B,
          new Map<String, String>{ 'AnnualRevenue' => '100' }
        ) // sem Company/LastName, sem match -> inválido p/ criar
      }
    );

    Test.startTest();
    SOLEnriquecimentoController.PreviewDTO pv = SOLEnriquecimentoController.classificar(
      lote
    );
    Test.stopTest();

    Assert.areEqual(2, pv.invalido, 'As duas linhas são inválidas.');
    Assert.areEqual(0, pv.semMatch, 'Nenhuma vira criação.');
  }

  @IsTest
  static void duplicadoNoArquivoNaoRecria() {
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    Id lote = SOLEnriquecimentoController.iniciarLote('f.csv', 2);
    adicionar(
      lote,
      new List<SOLEnriquecimentoController.LinhaDTO>{
        dto(1, CNPJ_B, valoresPadrao('100')),
        dto(2, CNPJ_B, valoresPadrao('200'))
      }
    );

    Test.startTest();
    SOLEnriquecimentoController.PreviewDTO pv = SOLEnriquecimentoController.classificar(
      lote
    );
    Test.stopTest();

    Assert.areEqual(1, pv.semMatch, 'A primeira cria.');
    Assert.areEqual(1, pv.duplicado, 'A segunda é duplicada no arquivo.');
  }

  @IsTest
  static void iniciarLoteBarraAcimaDoMaximo() {
    Boolean estourou = false;
    try {
      SOLEnriquecimentoController.iniciarLote('grande.csv', 5001);
    } catch (AuraHandledException e) {
      estourou = true;
      Assert.isTrue(
        e.getMessage().containsIgnoreCase('máximo'),
        'Mensagem deveria citar o máximo: ' + e.getMessage()
      );
    }
    Assert.isTrue(estourou, 'Deveria barrar acima de 5000 linhas.');
  }

  @IsTest
  static void getConfiguracaoDevolveMaximo() {
    Test.startTest();
    SOLEnriquecimentoController.ConfiguracaoDTO cfg = SOLEnriquecimentoController.getConfiguracao();
    Test.stopTest();
    Assert.areEqual(5000, cfg.maxLinhas, 'Máximo esperado é 5000.');
    Assert.isNotNull(cfg.mapeamentos, 'Lista de mapeamentos não deve ser nula.');
  }

  @IsTest
  static void confirmarEnfileiraEConsultaStatus() {
    SOLEnriquecimentoTestFactory.montarFila(2);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    Lead a = SOLEnriquecimentoTestFactory.novoLeadSOL('A', 'Emp A', CNPJ_A);

    Id lote = SOLEnriquecimentoController.iniciarLote('f.csv', 1);
    adicionar(
      lote,
      new List<SOLEnriquecimentoController.LinhaDTO>{
        dto(1, CNPJ_A, valoresPadrao('777'))
      }
    );
    SOLEnriquecimentoController.classificar(lote);

    Test.startTest();
    Id jobId = SOLEnriquecimentoController.confirmar(lote, null);
    Test.stopTest();

    Assert.isNotNull(jobId, 'Deveria devolver o Id do batch.');
    SOLEnriquecimentoController.StatusDTO st = SOLEnriquecimentoController.consultarStatus(
      lote
    );
    Assert.areEqual(1, st.qtdAtualizados, 'Deveria atualizar 1 linha.');
    Assert.areEqual(
      'Concluído',
      st.status,
      'Lote deveria concluir sem erros.'
    );
    Lead recarregado = [
      SELECT NumberOfEmployees
      FROM Lead
      WHERE Id = :a.Id
    ];
    Assert.areEqual(
      777,
      recarregado.NumberOfEmployees,
      'NumberOfEmployees deveria ter sido gravado (OVERWRITE).'
    );
  }
}

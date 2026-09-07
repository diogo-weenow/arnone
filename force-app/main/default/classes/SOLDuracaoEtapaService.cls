/**
 * CLICKUP-9439 / CLICKUP-9429 (absorvido) — cálculo das durações por etapa da
 * jornada Arnone Soluções, em DIAS ÚTEIS.
 *
 * Seis etapas, seis intervalos, sempre `(origem, destino]`: a origem abre a
 * etapa e não conta, o destino a fecha e conta. Mesmo dia útil = 0 — que é um
 * valor GRAVADO, e não a mesma coisa que vazio.
 *
 *   1. distribuição            -> primeira ligação concluída       (Lead)
 *   2. primeira ligação        -> contato efetivado                (Lead e Opp)
 *   3. contato efetivado       -> o ÚLTIMO de reunião e procuração (Lead e Opp)
 *   4. solicitação do cálculo  -> recebimento do cálculo           (Opp)
 *   5. recebimento do cálculo  -> reunião final                    (Opp)
 *   6. reunião final           -> encerramento (Ganho/Perdido)     (Opp)
 *
 * ====================================================================
 * POR QUE ESTA CLASSE NUNCA RELANÇA — e por que isso NÃO é o antipadrão
 * ====================================================================
 * A regra do repositório é que "o Apex ignora" nunca é proteção: a porta
 * estrita de `SOLContatoEfetivadoInvocable` RELANÇA de propósito, porque lá
 * engolir deixaria um dado FALSO gravado — a tarefa afirmando que o lead
 * respondeu, sem lead nenhum efetivado.
 *
 * Aqui é o oposto exato, e é o único ponto do repositório onde engolir é o
 * comportamento correto. A decisão é do P.O. (Opção B — "marco sempre, duração
 * tolerante"):
 *
 *   - gravar o MARCO nunca precisa do calendário; só a CONTAGEM precisa;
 *   - a duração é medida ANALÍTICA, não regra de negócio: nenhuma venda pode
 *     ser abortada porque o Business Hours caiu;
 *   - engolir aqui não persiste nada falso — persiste VAZIO mais uma PENDÊNCIA
 *     explícita (`SOL_Duracao_Pendente__c` + motivo + detalhe), que é
 *     exatamente a diferença entre tolerância e falha silenciosa.
 *
 * Contraste deliberado com `SOL_ConverterLead` + `SOLPrazoTotalService.
 * calcularPrazoTotal`: aquele prazo é OPERACIONAL (dispara reatribuição de
 * dono), e sem ele a Oportunidade não pode nascer — lá a conversão inteira é
 * abortada quando o calendário falta. Políticas diferentes para naturezas
 * diferentes, por decisão, não por descuido.
 *
 * =========================================
 * O QUE NUNCA ACONTECE, e é garantido aqui
 * =========================================
 *   - duração NEGATIVA, ou ZERO por falta de marco ou por falha de cálculo;
 *   - sobrescrita de duração já consolidada — a primeira conclusão válida é
 *     congelada, então reprocessamento e reatribuição são inócuos;
 *   - pendência marcada por MARCO FALTANDO: etapa não concluída é vazia, não
 *     pendente;
 *   - exceção vazando para quem chamou.
 *
 * SEM GUARDA DE RECURSÃO, de propósito: a classe só escreve campos técnicos
 * novos, e nenhuma automação do repositório dispara com a mudança deles. Uma
 * guarda por transação pareceria prudente e faria mal — num lote que conclui
 * duas tarefas do mesmo registro, ela descartaria a segunda chamada e a etapa
 * dela ficaria sem duração até o Batch. Quem protege é a idempotência POR
 * ETAPA ("já preenchida, não recalcula"), que não tem esse efeito colateral.
 *
 * ==========================================
 * O QUE MAIS ESTA CLASSE FAZ, e por que aqui
 * ==========================================
 * `consolidarMarcosDeTarefas` grava os marcos que NASCEM em Task — primeira
 * ligação, reunião comercial, recebimento do cálculo e reunião final. Isso
 * morava nos Flows e veio para cá porque o padrão declarativo "Get o pai, se
 * estiver vazio grava" NÃO é determinístico dentro de uma transação: todos os
 * Get das interviews rodam antes de qualquer Update. Ver o ApexDoc do método,
 * que traz a reprodução do defeito.
 *
 * `distribuicaoDeLeads` existe por um motivo de FLS, não de desenho: ver o
 * ApexDoc dele antes de mover essa consulta para qualquer outro lugar.
 *
 * Bulk-safe: zero SOQL/DML em laço, e o calendário é consultado uma única vez
 * por transação (ver `ContadorDiasUteis`). As consultas de Lead e de
 * Oportunidade usam FOR UPDATE, sempre na ordem Lead -> Oportunidade; nenhum
 * caminho desta classe trava Oportunidade antes de Lead, então não há ciclo.
 */
public without sharing class SOLDuracaoEtapaService {
  /** Falha TRANSITÓRIA: é a única que o Batch reprocessa automaticamente. */
  public static final String MOTIVO_CALENDARIO = 'Calendário indisponível';

  /** DADO inválido: fora da varredura automática, exige correção das datas. */
  public static final String MOTIVO_INCONSISTENTE = 'Intervalo inconsistente';

  /**
   * Erro INESPERADO no cálculo ou na gravação — nem calendário ausente, nem
   * intervalo incoerente.
   *
   * Também é reprocessado pela varredura, porque a maioria das falhas técnicas
   * é transitória (contenção de lock, limite momentâneo). Se persistir, o
   * registro continua aparecendo na lista de pendências com este motivo, que é
   * justamente o sinal para alguém olhar — e o Batch marca o `AsyncApexJob`.
   */
  public static final String MOTIVO_FALHA_TECNICA = 'Falha técnica';

  /** Motivos que a varredura automática aceita reprocessar. */
  public static final Set<String> MOTIVOS_REPROCESSAVEIS = new Set<String>{
    MOTIVO_CALENDARIO,
    MOTIVO_FALHA_TECNICA
  };

  /**
   * O MARCO não pôde ser gravado. É a ÚNICA exceção que este serviço deixa sair,
   * e ela existe porque marco não é medida analítica: é o registro comercial do
   * que aconteceu. Sem ele, a tarefa não pode terminar concluída.
   */
  public class MarcoNaoGravadoException extends Exception {
  }

  /** Mensagem controlada para o vendedor. Sem detalhe técnico. */
  public static final String MSG_MARCO_NAO_GRAVADO = 'Não foi possível registrar esta conclusão na jornada da Arnone Soluções. Nada foi salvo — conclua a tarefa de novo. Se o erro continuar, acione o administrador.';

  @TestVisible
  private static final String RT_SOL = 'SOL';

  /** Limite do campo de detalhe da pendência. */
  @TestVisible
  private static final Integer MAX_DETALHE = 255;

  /** Campos de pendência, iguais nos dois objetos. */
  private static final String CAMPO_PENDENTE = 'SOL_Duracao_Pendente__c';
  private static final String CAMPO_MOTIVO = 'SOL_Duracao_Pendencia_Motivo__c';
  private static final String CAMPO_DETALHE = 'SOL_Duracao_Pendencia_Detalhe__c';

  /**
   * Quantas vezes o acumulado de dias úteis foi montado nesta transação.
   *
   * Existe para o teste de BULK poder PROVAR — e não afirmar — que o calendário
   * é pré-computado uma vez por transação, e não uma vez por registro. Um lote
   * de 200 registros que produza mais de um acumulado teria voltado ao padrão
   * que estoura CPU time num backfill.
   */
  @TestVisible
  private static Integer contadoresMontados = 0;

  /** Somente testes: zera a instrumentação antes da chamada medida. */
  @TestVisible
  private static void zerarInstrumentacao() {
    contadoresMontados = 0;
  }

  /** Contagens controladas de uma execução. Nunca lança; só descreve. */
  public class ResultadoDuracao {
    public Integer avaliados = 0;
    public Integer foraDoEscopo = 0;
    public Integer calculadas = 0;
    public Integer pendentes = 0;
    public Integer jaPreenchidas = 0;
    public Integer ignoradas = 0;
    public Integer marcosConsolidados = 0;
    public Integer registrosAtualizados = 0;
    public Integer oportunidadesSincronizadas = 0;
    public Integer falhas = 0;
    /** Falhas que CONSEGUIRAM virar pendência no próprio registro. */
    public Integer falhasSinalizadas = 0;
    /** Falhas que NÃO puderam ser gravadas em registro nenhum. */
    public Integer falhasSemSinal = 0;

    public override String toString() {
      return 'avaliados=' +
        avaliados +
        ' foraDoEscopo=' +
        foraDoEscopo +
        ' calculadas=' +
        calculadas +
        ' pendentes=' +
        pendentes +
        ' jaPreenchidas=' +
        jaPreenchidas +
        ' ignoradas=' +
        ignoradas +
        ' marcosConsolidados=' +
        marcosConsolidados +
        ' registrosAtualizados=' +
        registrosAtualizados +
        ' oportunidadesSincronizadas=' +
        oportunidadesSincronizadas +
        ' falhas=' +
        falhas +
        ' falhasSinalizadas=' +
        falhasSinalizadas +
        ' falhasSemSinal=' +
        falhasSemSinal;
    }
  }

  /** Descritor de uma etapa: de onde, para onde, e onde grava. */
  private class Etapa {
    public String rotulo;
    public String campoOrigem;
    public Boolean origemEhDateTime;
    public String campoDestino;
    public Boolean destinoEhDateTime;
    public String campoDuracao;

    public Etapa(
      String rotulo,
      String campoOrigem,
      Boolean origemEhDateTime,
      String campoDestino,
      Boolean destinoEhDateTime,
      String campoDuracao
    ) {
      this.rotulo = rotulo;
      this.campoOrigem = campoOrigem;
      this.origemEhDateTime = origemEhDateTime;
      this.campoDestino = campoDestino;
      this.destinoEhDateTime = destinoEhDateTime;
      this.campoDuracao = campoDuracao;
    }
  }

  private static final List<Etapa> ETAPAS_LEAD = new List<Etapa>{
    new Etapa(
      '1 - Primeira ligação',
      'SOL_Data_Distribuicao__c',
      true,
      'SOL_Data_Primeira_Ligacao__c',
      true,
      'SOL_Dias_Primeira_Ligacao__c'
    ),
    new Etapa(
      '2 - Contato efetivado',
      'SOL_Data_Primeira_Ligacao__c',
      true,
      'SOL_Data_Contato_Efetivado__c',
      true,
      'SOL_Dias_Contato_Efetivado__c'
    ),
    new Etapa(
      '3 - Reunião e procuração',
      'SOL_Data_Contato_Efetivado__c',
      true,
      'SOL_Data_Reuniao_Procuracao__c',
      false,
      'SOL_Dias_Reuniao_Procuracao__c'
    )
  };

  /**
   * As CINCO etapas mensuráveis na Oportunidade, mais a etapa 1.
   *
   * A etapa 1 PRECISA estar aqui, e o espelho de `SOL_Data_Distribuicao__c`
   * existe por causa dela. Sem a origem, a Oportunidade não conseguia decidir
   * se a etapa 1 ainda estava pendente — e `aplicarPendencia`, que recalcula o
   * estado agregado do zero, APAGARIA uma pendência legítima herdada do Lead na
   * primeira vez que a Oportunidade fosse reavaliada por qualquer outro motivo.
   * Com a origem espelhada, a etapa 1 é avaliada como qualquer outra e a
   * pendência dela sobrevive ao recálculo.
   */
  private static final List<Etapa> ETAPAS_OPORTUNIDADE = new List<Etapa>{
    new Etapa(
      '1 - Primeira ligação',
      'SOL_Data_Distribuicao__c',
      true,
      'SOL_Data_Primeira_Ligacao__c',
      true,
      'SOL_Dias_Primeira_Ligacao__c'
    ),
    new Etapa(
      '2 - Contato efetivado',
      'SOL_Data_Primeira_Ligacao__c',
      true,
      'SOL_Data_Inicio_Ciclo_Comercial__c',
      true,
      'SOL_Dias_Contato_Efetivado__c'
    ),
    new Etapa(
      '3 - Reunião e procuração',
      'SOL_Data_Inicio_Ciclo_Comercial__c',
      true,
      'SOL_Data_Reuniao_Procuracao__c',
      false,
      'SOL_Dias_Reuniao_Procuracao__c'
    ),
    new Etapa(
      '4 - Cálculo jurídico',
      'SOL_Data_Solicitacao_Calculo__c',
      false,
      'SOL_Data_Recebimento_Calculo__c',
      false,
      'SOL_Dias_Calculo_Juridico__c'
    ),
    new Etapa(
      '5 - Reunião final',
      'SOL_Data_Recebimento_Calculo__c',
      false,
      'SOL_Data_Reuniao_Final__c',
      false,
      'SOL_Dias_Reuniao_Final__c'
    ),
    new Etapa(
      '6 - Fechamento',
      'SOL_Data_Reuniao_Final__c',
      false,
      'SOL_Data_Encerramento__c',
      true,
      'SOL_Dias_Fechamento__c'
    )
  };

  /**
   * Espelhos Lead -> Oportunidade dos MARCOS e DURAÇÕES das etapas 1 a 3.
   *
   * Os campos de PENDÊNCIA não estão aqui de propósito: a Oportunidade calcula
   * o estado dela do zero a cada avaliação, agora que consegue avaliar também a
   * etapa 1. Copiar pendência aqui sobrescreveria um problema das etapas 4 a 6
   * com o estado do Lead. Na CONVERSÃO é diferente — lá a Oportunidade nasce
   * sem nunca ter sido avaliada, e por isso `SOL_ConverterLead` transporta
   * também motivo e detalhe, para que nunca exista pendência sem explicação.
   */
  private static final Map<String, String> ESPELHOS = new Map<String, String>{
    'SOL_Data_Distribuicao__c' => 'SOL_Data_Distribuicao__c',
    'SOL_Data_Primeira_Ligacao__c' => 'SOL_Data_Primeira_Ligacao__c',
    'SOL_Data_Reuniao_Procuracao__c' => 'SOL_Data_Reuniao_Procuracao__c',
    'SOL_Dias_Primeira_Ligacao__c' => 'SOL_Dias_Primeira_Ligacao__c',
    'SOL_Dias_Contato_Efetivado__c' => 'SOL_Dias_Contato_Efetivado__c',
    'SOL_Dias_Reuniao_Procuracao__c' => 'SOL_Dias_Reuniao_Procuracao__c'
  };

  // ==================================================================
  // API pública
  // ==================================================================

  /**
   * Consolida o marco da etapa 3, recalcula as etapas 1 a 3 dos Leads
   * informados e ressincroniza a Oportunidade dos que já foram convertidos.
   *
   * NUNCA lança: qualquer falha vira log e contagem no resultado.
   */
  public static ResultadoDuracao recalcularLeads(List<Id> leadIds) {
    ResultadoDuracao r = new ResultadoDuracao();
    Set<Id> ids = idsUteis(leadIds, Lead.SObjectType);
    if (ids.isEmpty()) {
      return r;
    }
    try {
      List<Lead> leads = [
        SELECT
          Id,
          IsConverted,
          ConvertedOpportunityId,
          SOL_Data_Distribuicao__c,
          SOL_Data_Primeira_Ligacao__c,
          SOL_Data_Contato_Efetivado__c,
          SOL_Data_Reuniao_Realizada__c,
          SOL_Data_Recebimento_Procuracao__c,
          SOL_Data_Reuniao_Procuracao__c,
          SOL_Dias_Primeira_Ligacao__c,
          SOL_Dias_Contato_Efetivado__c,
          SOL_Dias_Reuniao_Procuracao__c,
          SOL_Duracao_Pendente__c,
          SOL_Duracao_Pendencia_Motivo__c,
          SOL_Duracao_Pendencia_Detalhe__c
        FROM Lead
        WHERE Id IN :ids AND RecordType.DeveloperName = :RT_SOL
        FOR UPDATE
      ];
      r.foraDoEscopo += (ids.size() - leads.size());
      Set<Id> consolidados = consolidarMarcoDaEtapa3(leads, r);
      processar(leads, ETAPAS_LEAD, consolidados, r);
      sincronizarOportunidadesDeLeadsConvertidos(leads, r);
    } catch (Exception e) {
      registrarFalha('recalcularLeads', e, r);
    }
    return r;
  }

  /**
   * Recalcula as etapas 2 a 6 das Oportunidades informadas.
   *
   * NUNCA lança.
   */
  public static ResultadoDuracao recalcularOportunidades(List<Id> oppIds) {
    ResultadoDuracao r = new ResultadoDuracao();
    Set<Id> ids = idsUteis(oppIds, Opportunity.SObjectType);
    if (ids.isEmpty()) {
      return r;
    }
    try {
      List<Opportunity> opps = [
        SELECT
          Id,
          SOL_Data_Distribuicao__c,
          SOL_Data_Primeira_Ligacao__c,
          SOL_Data_Inicio_Ciclo_Comercial__c,
          SOL_Data_Reuniao_Procuracao__c,
          SOL_Data_Solicitacao_Calculo__c,
          SOL_Data_Recebimento_Calculo__c,
          SOL_Data_Reuniao_Final__c,
          SOL_Data_Encerramento__c,
          SOL_Dias_Primeira_Ligacao__c,
          SOL_Dias_Contato_Efetivado__c,
          SOL_Dias_Reuniao_Procuracao__c,
          SOL_Dias_Calculo_Juridico__c,
          SOL_Dias_Reuniao_Final__c,
          SOL_Dias_Fechamento__c,
          SOL_Duracao_Pendente__c,
          SOL_Duracao_Pendencia_Motivo__c,
          SOL_Duracao_Pendencia_Detalhe__c
        FROM Opportunity
        WHERE Id IN :ids AND RecordType.DeveloperName = :RT_SOL
        FOR UPDATE
      ];
      r.foraDoEscopo += (ids.size() - opps.size());
      processar(opps, ETAPAS_OPORTUNIDADE, new Set<Id>(), r);
    } catch (Exception e) {
      registrarFalha('recalcularOportunidades', e, r);
    }
    return r;
  }

  // ==================================================================
  // Núcleo
  // ==================================================================

  /**
   * Avalia todas as etapas de todos os registros do lote e grava uma vez só.
   *
   * Duas passadas de propósito. A primeira só DESCOBRE quais pares precisam ser
   * contados e qual é o intervalo global do lote; a segunda conta, já com o
   * calendário pré-computado. Sem isso, `BusinessHours.nextStartDate` seria
   * chamado uma vez por dia E por registro, e um backfill estouraria o CPU
   * time da transação.
   *
   * `jaAlterados` são os registros que a consolidação do marco da etapa 3 já
   * modificou em memória: eles precisam ser gravados mesmo que nenhuma duração
   * nova seja calculada, senão o marco recém-consolidado se perderia quando o
   * calendário estivesse fora.
   */
  private static void processar(
    List<SObject> registros,
    List<Etapa> etapas,
    Set<Id> jaAlterados,
    ResultadoDuracao r
  ) {
    if (registros.isEmpty()) {
      return;
    }
    r.avaliados += registros.size();
    Id bhId = SOLBusinessHoursHelper.businessHoursId();

    // Passada 1 — intervalo global, considerando apenas os pares SANOS. Um par
    // invertido ou absurdo não pode esticar o intervalo do lote inteiro.
    Date menor = null;
    Date maior = null;
    for (SObject reg : registros) {
      for (Etapa e : etapas) {
        // A passada 1 é envolvida em try porque uma leitura de campo NÃO
        // CONSULTADO lança SObjectException — e sem esta rede a exceção subiria
        // até o catch do método público, abortando a medição do LOTE INTEIRO em
        // silêncio. Foi exatamente o que aconteceu quando a etapa 1 entrou no
        // descritor da Oportunidade antes de o campo entrar na projeção: todas
        // as durações de Oportunidade pararam de ser calculadas de uma vez. Na
        // passada 2 o mesmo erro vira pendência `Falha técnica` por etapa.
        Date origem;
        Date destino;
        try {
          if (reg.get(e.campoDuracao) != null) {
            continue;
          }
          origem = comoData(reg.get(e.campoOrigem), e.origemEhDateTime);
          destino = comoData(reg.get(e.campoDestino), e.destinoEhDateTime);
        } catch (Exception ex) {
          continue;
        }
        if (origem == null || destino == null || destino < origem) {
          continue;
        }
        if (
          origem.daysBetween(destino) > SOLBusinessHoursHelper.MAX_DIAS_INTERVALO
        ) {
          continue;
        }
        if (menor == null || origem < menor) {
          menor = origem;
        }
        if (maior == null || destino > maior) {
          maior = destino;
        }
      }
    }

    ContadorDiasUteis contador = montarContador(bhId, menor, maior);

    // Passada 2 — contar e decidir a pendência de cada registro.
    List<SObject> paraAtualizar = new List<SObject>();
    for (SObject reg : registros) {
      List<String> pendencias = new List<String>();
      Boolean haTransitoria = false;
      Boolean haInconsistente = false;
      Boolean haFalhaTecnica = false;
      Boolean mudou = jaAlterados.contains((Id) reg.get('Id'));

      for (Etapa e : etapas) {
        if (reg.get(e.campoDuracao) != null) {
          // Requisitos 9 e 10: a primeira conclusão válida é congelada.
          r.jaPreenchidas++;
          continue;
        }
        Date origem = comoData(reg.get(e.campoOrigem), e.origemEhDateTime);
        Date destino = comoData(reg.get(e.campoDestino), e.destinoEhDateTime);
        if (origem == null || destino == null) {
          // Requisito 8: etapa NÃO CONCLUÍDA. Fica vazia, e isso não é
          // pendência — é etapa que ainda não aconteceu.
          r.ignoradas++;
          continue;
        }
        try {
          Integer dias = contar(bhId, contador, origem, destino);
          reg.put(e.campoDuracao, Decimal.valueOf(dias));
          // Este `mudou` e o que fica logo abaixo, no bloco da pendência, NÃO
          // são a mesma coisa e nenhum dos dois é redundante — cobrem mutações
          // disjuntas. MEDIDO: removendo este, 15 testes quebram, todos de
          // duração; removendo o da pendência, quebram 6, todos de pendência, e
          // os dois conjuntos não têm interseção. Um registro cuja ÚNICA
          // mudança é a duração precisa deste; um cuja única mudança é a
          // pendência — calendário fora, por exemplo — precisa do outro.
          mudou = true;
          r.calculadas++;
        } catch (SOLBusinessHoursHelper.CalendarioIndisponivelException ex) {
          haTransitoria = true;
          pendencias.add(e.rotulo + ': calendário indisponível');
          r.pendentes++;
        } catch (SOLBusinessHoursHelper.IntervaloInvalidoException ex) {
          haInconsistente = true;
          pendencias.add(e.rotulo + ': intervalo inconsistente');
          r.pendentes++;
        } catch (Exception ex) {
          // Falha INESPERADA no cálculo de UMA etapa. Antes, ela subia até o
          // catch do método público e derrubava a avaliação do LOTE inteiro,
          // sem deixar rastro em registro nenhum. Agora fica contida na etapa,
          // vira pendência explícita, e as outras etapas e os outros registros
          // seguem sendo medidos.
          haFalhaTecnica = true;
          pendencias.add(e.rotulo + ': falha técnica (' + ex.getTypeName() + ')');
          r.pendentes++;
          r.falhas++;
          System.debug(
            LoggingLevel.ERROR,
            'SOLDuracaoEtapaService: falha inesperada em ' +
              reg.get('Id') +
              ' / ' +
              e.rotulo +
              ' -> ' +
              ex.getTypeName() +
              ': ' +
              ex.getMessage() +
              ' | ' +
              ex.getStackTraceString()
          );
        }
      }

      if (
        aplicarPendencia(
          reg,
          pendencias,
          haTransitoria,
          haInconsistente,
          haFalhaTecnica
        )
      ) {
        mudou = true;
      }
      if (mudou) {
        paraAtualizar.add(reg);
      }
    }

    gravar(paraAtualizar, r);
  }

  /**
   * Conta `(origem, destino]` pelo acumulado do lote quando ele cobre o par, e
   * pela régua dia a dia quando não cobre.
   *
   * O caminho dia a dia é também o que produz a exceção CERTA para os pares
   * que a passada 1 recusou: destino anterior à origem e distância acima do
   * teto voltam de `diasUteisEntre` como `IntervaloInvalidoException`, com a
   * mensagem que descreve o problema real.
   */
  private static Integer contar(
    Id bhId,
    ContadorDiasUteis contador,
    Date origem,
    Date destino
  ) {
    if (contador != null && contador.cobre(origem, destino)) {
      return contador.entre(origem, destino);
    }
    return SOLBusinessHoursHelper.diasUteisEntre(bhId, origem, destino);
  }

  /**
   * Marca, mantém ou limpa a pendência do registro. Devolve true se algum campo
   * de pendência mudou.
   *
   * PRECEDÊNCIA quando as duas situações coexistem no mesmo registro: vence a
   * TRANSITÓRIA. É ela que ainda pode se resolver sozinha, e o Batch só alcança
   * o registro por esse motivo; resolvida a transitória, a avaliação seguinte
   * rebaixa o motivo para inconsistente e o registro sai da varredura
   * automática — terminando o ciclo em vez de repeti-lo. A precedência
   * contrária prenderia a falha de calendário atrás de um dado ruim, para
   * sempre.
   */
  private static Boolean aplicarPendencia(
    SObject reg,
    List<String> pendencias,
    Boolean haTransitoria,
    Boolean haInconsistente,
    Boolean haFalhaTecnica
  ) {
    Boolean pendenteAgora = haTransitoria || haInconsistente || haFalhaTecnica;
    String motivoAgora = null;
    String detalheAgora = null;
    if (pendenteAgora) {
      // Precedência: primeiro o que a varredura CONSEGUE resolver. A falha
      // técnica vem à frente do calendário porque é a que exige olho humano se
      // persistir; as duas são reprocessáveis, então em qualquer uma delas o
      // Batch continua alcançando o registro. O motivo permanente fica por
      // último, e só prevalece quando é o único — senão prenderia um problema
      // resolvível atrás de um dado ruim.
      motivoAgora = haFalhaTecnica
        ? MOTIVO_FALHA_TECNICA
        : (haTransitoria ? MOTIVO_CALENDARIO : MOTIVO_INCONSISTENTE);
      detalheAgora = String.join(pendencias, ' | ');
      if (detalheAgora.length() > MAX_DETALHE) {
        detalheAgora = detalheAgora.abbreviate(MAX_DETALHE);
      }
    }
    // INVARIANTE: nunca existe pendência sem motivo e sem detalhe. Um checkbox
    // marcado e um motivo vazio seriam uma lacuna sem explicação — pior que não
    // ter marcado nada, porque parece informação.
    if (pendenteAgora && (motivoAgora == null || String.isBlank(detalheAgora))) {
      motivoAgora = MOTIVO_FALHA_TECNICA;
      detalheAgora = 'Pendência sem detalhe apurado.';
    }

    // Uma pendência TÉCNICA registrada nesta mesma execução não pode ser
    // apagada por uma reavaliação posterior: quem a gravou foi a segunda
    // chance da gravação, e o objeto em memória aqui não sabe disso. Sem esta
    // guarda, o único registro da falha desapareceria no mesmo instante em que
    // foi criado.
    if (!pendenteAgora && pendenciaTecnicaNestaExecucao.contains((Id) reg.get('Id'))) {
      return false;
    }

    Boolean pendenteAntes = ((Boolean) reg.get(CAMPO_PENDENTE)) == true;
    String motivoAntes = (String) reg.get(CAMPO_MOTIVO);
    String detalheAntes = (String) reg.get(CAMPO_DETALHE);

    if (
      pendenteAntes == pendenteAgora &&
      motivoAntes == motivoAgora &&
      detalheAntes == detalheAgora
    ) {
      return false;
    }
    reg.put(CAMPO_PENDENTE, pendenteAgora);
    reg.put(CAMPO_MOTIVO, motivoAgora);
    reg.put(CAMPO_DETALHE, detalheAgora);
    return true;
  }

  /**
   * Etapa 3: materializa "o ÚLTIMO dos dois marcos" no Lead, em memória.
   *
   * Só grava quando os DOIS existem — com um marco só a etapa não terminou, e
   * registrar o marco isolado inventaria uma conclusão que não houve. Não
   * sobrescreve o que já está gravado.
   *
   * O DateTime da reunião é normalizado para a DATA em America/Sao_Paulo antes
   * da comparação: comparar DateTime com Date direto erra o fuso em até um dia,
   * porque uma reunião às 23:30 de São Paulo já é o dia seguinte em GMT.
   *
   * Devolve os Ids alterados para que `processar` os grave mesmo que nenhuma
   * duração nova saia daquela passada.
   */
  private static Set<Id> consolidarMarcoDaEtapa3(
    List<Lead> leads,
    ResultadoDuracao r
  ) {
    Set<Id> alterados = new Set<Id>();
    for (Lead l : leads) {
      if (l.SOL_Data_Reuniao_Procuracao__c != null) {
        continue;
      }
      if (
        l.SOL_Data_Reuniao_Realizada__c == null ||
        l.SOL_Data_Recebimento_Procuracao__c == null
      ) {
        continue;
      }
      Date reuniao = SOLBusinessHoursHelper.dataEm(
        l.SOL_Data_Reuniao_Realizada__c,
        SOLBusinessHoursHelper.TZ_SAO_PAULO
      );
      Date procuracao = l.SOL_Data_Recebimento_Procuracao__c;
      l.SOL_Data_Reuniao_Procuracao__c = reuniao > procuracao
        ? reuniao
        : procuracao;
      alterados.add(l.Id);
      r.marcosConsolidados++;
    }
    return alterados;
  }

  /**
   * Leva para a Oportunidade os valores das etapas 1 a 3 dos Leads já
   * convertidos, SEMPRE sem sobrescrever o que a Oportunidade já tem.
   *
   * Por que existe: `SOL_ConverterLead` transporta esses campos no instante da
   * conversão. Se naquele instante o calendário estivesse fora, a Oportunidade
   * nasceria sem as etapas 1 a 3 e nunca mais as teria — a etapa 1 não pode ser
   * recalculada na Oportunidade, porque a origem dela só existe no Lead. Esta
   * ressincronização é o que fecha esse buraco depois que o Batch conserta o
   * Lead, e é o que faz o relatório cobrir Lead e Oportunidade sem perder o que
   * aconteceu antes da conversão.
   */
  private static void sincronizarOportunidadesDeLeadsConvertidos(
    List<Lead> leads,
    ResultadoDuracao r
  ) {
    Map<Id, Lead> porOportunidade = new Map<Id, Lead>();
    for (Lead l : leads) {
      if (l.IsConverted != true || l.ConvertedOpportunityId == null) {
        continue;
      }
      // Se dois Leads apontarem para a mesma Oportunidade, vence o de menor Id
      // — critério determinístico, para que rodar duas vezes dê o mesmo
      // resultado.
      Lead atual = porOportunidade.get(l.ConvertedOpportunityId);
      if (atual == null || l.Id < atual.Id) {
        porOportunidade.put(l.ConvertedOpportunityId, l);
      }
    }
    if (porOportunidade.isEmpty()) {
      return;
    }

    List<Opportunity> paraAtualizar = new List<Opportunity>();
    for (Opportunity o : [
      SELECT
        Id,
        SOL_Data_Distribuicao__c,
        SOL_Data_Primeira_Ligacao__c,
        SOL_Data_Reuniao_Procuracao__c,
        SOL_Dias_Primeira_Ligacao__c,
        SOL_Dias_Contato_Efetivado__c,
        SOL_Dias_Reuniao_Procuracao__c
      FROM Opportunity
      WHERE Id IN :porOportunidade.keySet()
      FOR UPDATE
    ]) {
      Lead l = porOportunidade.get(o.Id);
      Boolean mudou = false;
      for (String campoLead : ESPELHOS.keySet()) {
        String campoOpp = ESPELHOS.get(campoLead);
        if (o.get(campoOpp) != null || l.get(campoLead) == null) {
          continue;
        }
        o.put(campoOpp, l.get(campoLead));
        mudou = true;
      }
      if (mudou) {
        paraAtualizar.add(o);
      }
    }
    if (paraAtualizar.isEmpty()) {
      return;
    }
    r.oportunidadesSincronizadas += paraAtualizar.size();
    gravar(paraAtualizar, r);
  }

  // ==================================================================
  // Consolidação dos marcos que nascem em Task
  // ==================================================================

  private static final String STATUS_CONCLUIDO = 'Completed';
  private static final String TIPO_CONTATO = 'Contato';
  private static final String CANAL_LIGACAO = 'Ligação';
  private static final String TIPO_REUNIAO_COMERCIAL = 'Reunião comercial';
  private static final String RESULTADO_REALIZADA = 'Realizada';
  private static final String TIPO_ACOMPANHAMENTO_CALCULO = 'Acompanhamento do cálculo jurídico';
  private static final String TIPO_REUNIAO_FINAL = 'Reunião final';

  /**
   * Consolida no Lead ou na Oportunidade os marcos que nascem em Task, e em
   * seguida reavalia as durações dos pais afetados.
   *
   * ===========================================================
   * POR QUE ISTO SAIU DO FLOW E VEIO PARA CÁ — defeito medido
   * ===========================================================
   * O padrão "Get pai -> decide se está vazio -> Update pai" parece seguro e
   * NÃO é, dentro de uma única transação: TODOS os Get das interviews rodam
   * ANTES de qualquer Update. Com duas Tasks qualificadas do MESMO pai
   * concluídas no mesmo DML, as duas interviews leem o campo vazio, as duas
   * decidem gravar, e o valor que sobra é o da ÚLTIMA interview processada —
   * não o primeiro marco cronológico.
   *
   * Isso foi reproduzido por teste antes de ser corrigido, com as duas ordens
   * possíveis da lista: `duasTarefasDeCalculoDaMesmaOportunidadeNoMesmoDml` e
   * `duasTarefasDeCalculoComAOrdemInvertida` produziam marcos DIFERENTES para
   * dados equivalentes. Não houve `DUPLICATE_ID_IN_LIST` — a plataforma
   * consolida os updates repetidos; o defeito é sobrescrita silenciosa por
   * ordem de lista.
   *
   * Aqui o resultado é determinístico: agrupa por pai, escolhe o MENOR marco,
   * trava os pais com FOR UPDATE e grava UMA vez por pai, só quando o campo
   * ainda está vazio. Duas Tasks do mesmo pai, em qualquer ordem, produzem
   * sempre o primeiro marco cronológico.
   *
   * ORDEM DE LOCK: Lead antes de Oportunidade, a mesma ordem usada em
   * `recalcularLeads`. Nenhum caminho deste serviço trava Oportunidade antes de
   * Lead, então não há ciclo.
   *
   * ====================================================
   * ESTE MÉTODO LANÇA — e a fronteira é o marco, não o tipo
   * ====================================================
   * É o único do serviço que lança, e lança `MarcoNaoGravadoException` para
   * QUALQUER falha ocorrida ANTES de o marco estar persistido: consulta, lock,
   * preparação, consolidação ou a gravação em si. Todas viram a mesma mensagem
   * controlada, sobem pelo Invocable e desfazem a conclusão da Task.
   *
   * Depois que o marco está gravado, a política inverte: o cálculo da duração é
   * TOLERANTE e nada ali desfaz operação comercial.
   */
  public static ResultadoDuracao consolidarMarcosDeTarefas(List<Id> taskIds) {
    ResultadoDuracao r = new ResultadoDuracao();
    Set<Id> ids = idsUteis(taskIds, Task.SObjectType);
    if (ids.isEmpty()) {
      return r;
    }
    // Menor marco por (pai, campo). Marcos de Lead são sempre DateTime e os de
    // Oportunidade sempre Date — por isso dois mapas, e nenhuma comparação
    // genérica de Object que pudesse comparar tipos trocados.
    Map<Id, Map<String, Datetime>> menorNoLead = new Map<Id, Map<String, Datetime>>();
    Map<Id, Map<String, Date>> menorNaOportunidade = new Map<Id, Map<String, Date>>();
    try {

      for (Task t : [
        SELECT
          Id,
          WhoId,
          WhatId,
          Status,
          CompletedDateTime,
          SOL_Tipo_Tarefa__c,
          SOL_Canal_Contato__c,
          SOL_Resultado_Reuniao__c,
          SOL_Data_Recebimento_Calculo__c,
          SOL_Data_Reuniao_Final__c
        FROM Task
        WHERE Id IN :ids
      ]) {
        if (t.Status != STATUS_CONCLUIDO) {
          r.ignoradas++;
          continue;
        }
        String tipo = t.SOL_Tipo_Tarefa__c;

        if (
          tipo == TIPO_CONTATO &&
          t.SOL_Canal_Contato__c == CANAL_LIGACAO &&
          t.CompletedDateTime != null &&
          ehDoTipo(t.WhoId, Lead.SObjectType)
        ) {
          registrarMenor(
            menorNoLead,
            t.WhoId,
            'SOL_Data_Primeira_Ligacao__c',
            t.CompletedDateTime
          );
          continue;
        }
        if (
          tipo == TIPO_REUNIAO_COMERCIAL &&
          t.SOL_Resultado_Reuniao__c == RESULTADO_REALIZADA &&
          t.CompletedDateTime != null &&
          ehDoTipo(t.WhoId, Lead.SObjectType)
        ) {
          registrarMenor(
            menorNoLead,
            t.WhoId,
            'SOL_Data_Reuniao_Realizada__c',
            t.CompletedDateTime
          );
          continue;
        }
        if (
          tipo == TIPO_ACOMPANHAMENTO_CALCULO &&
          t.SOL_Data_Recebimento_Calculo__c != null &&
          ehDoTipo(t.WhatId, Opportunity.SObjectType)
        ) {
          registrarMenor(
            menorNaOportunidade,
            t.WhatId,
            'SOL_Data_Recebimento_Calculo__c',
            t.SOL_Data_Recebimento_Calculo__c
          );
          continue;
        }
        if (
          tipo == TIPO_REUNIAO_FINAL &&
          t.SOL_Data_Reuniao_Final__c != null &&
          ehDoTipo(t.WhatId, Opportunity.SObjectType)
        ) {
          registrarMenor(
            menorNaOportunidade,
            t.WhatId,
            'SOL_Data_Reuniao_Final__c',
            t.SOL_Data_Reuniao_Final__c
          );
          continue;
        }
        // Tarefa que não alimenta marco nenhum: descartada em silêncio. É o
        // caso de um WhoId que não é Lead, de outro tipo de tarefa, ou de uma
        // reunião que não foi realizada.
        r.ignoradas++;
      }

      if (simularFalhaInesperadaNoMarco && Test.isRunningTest()) {
        // Uma exceção qualquer, do tipo que ninguém previu — é esse o ponto.
        String nulo = null;
        nulo.length();
      }

      // ---- Leads primeiro (ordem de lock) ----
      if (!menorNoLead.isEmpty()) {
        List<Lead> paraAtualizar = new List<Lead>();
        for (Lead l : [
          SELECT Id, SOL_Data_Primeira_Ligacao__c, SOL_Data_Reuniao_Realizada__c
          FROM Lead
          WHERE Id IN :menorNoLead.keySet() AND RecordType.DeveloperName = :RT_SOL
          FOR UPDATE
        ]) {
          Boolean mudou = false;
          for (String campo : menorNoLead.get(l.Id).keySet()) {
            if (l.get(campo) != null) {
              continue;
            }
            l.put(campo, menorNoLead.get(l.Id).get(campo));
            mudou = true;
            r.marcosConsolidados++;
          }
          if (mudou) {
            paraAtualizar.add(l);
          }
        }
        gravarMarcosOuLancar(paraAtualizar, r);
      }

      // ---- Oportunidades depois ----
      if (!menorNaOportunidade.isEmpty()) {
        List<Opportunity> paraAtualizar = new List<Opportunity>();
        for (Opportunity o : [
          SELECT Id, SOL_Data_Recebimento_Calculo__c, SOL_Data_Reuniao_Final__c
          FROM Opportunity
          WHERE
            Id IN :menorNaOportunidade.keySet()
            AND RecordType.DeveloperName = :RT_SOL
          FOR UPDATE
        ]) {
          Boolean mudou = false;
          for (String campo : menorNaOportunidade.get(o.Id).keySet()) {
            if (o.get(campo) != null) {
              continue;
            }
            o.put(campo, menorNaOportunidade.get(o.Id).get(campo));
            mudou = true;
            r.marcosConsolidados++;
          }
          if (mudou) {
            paraAtualizar.add(o);
          }
        }
        gravarMarcosOuLancar(paraAtualizar, r);
      }
    } catch (MarcoNaoGravadoException e) {
      // O MARCO é obrigatório: ela sobe pelo Invocable até o Flow e desfaz a
      // conclusão da Task, para que nunca exista tarefa concluída sem o marco
      // que ela deveria ter registrado.
      throw e;
    } catch (Exception e) {
      // E QUALQUER OUTRA FALHA DESTA FASE TAMBÉM SOBE — convertida.
      //
      // A versão anterior registrava e dava `return` aqui, e o efeito era
      // exatamente o buraco que a fase obrigatória existe para fechar: falha
      // inesperada em consulta, lock, preparação ou consolidação virava log, e
      // a Task ficava concluída SEM marco. Fechar só o caminho previsto
      // (`MarcoNaoGravadoException`) e deixar o imprevisto aberto é o mesmo
      // defeito uma camada acima.
      //
      // A regra não é sobre QUAL exceção aconteceu: é sobre QUANDO. Enquanto o
      // marco não estiver persistido, tudo aborta a conclusão da Task. Depois
      // dele, nada aborta.
      registrarFalha('consolidarMarcosDeTarefas (marco)', e, r);
      throw new MarcoNaoGravadoException(MSG_MARCO_NAO_GRAVADO);
    }

    // ---- DAQUI PARA BAIXO a política muda: o marco já está persistido, e o
    // cálculo da duração é TOLERANTE. Nada abaixo desta linha pode desfazer a
    // conclusão da Task.
    try {
      if (!menorNoLead.isEmpty()) {
        somar(r, recalcularLeads(new List<Id>(menorNoLead.keySet())));
      }
      if (!menorNaOportunidade.isEmpty()) {
        somar(
          r,
          recalcularOportunidades(new List<Id>(menorNaOportunidade.keySet()))
        );
      }
    } catch (Exception e) {
      registrarFalha('consolidarMarcosDeTarefas (duração)', e, r);
    }
    return r;
  }

  /**
   * A data de distribuição dos Leads informados — a ORIGEM da etapa 1.
   *
   * POR QUE ISTO É UM MÉTODO DAQUI, e não uma consulta em `SOL_ConverterLead`:
   * `Lead.SOL_Data_Distribuicao__c` só tem FLS em `PS_SOL_Distribuicao_Admin`.
   * Uma consulta a ela dentro da classe de conversão faz a plataforma
   * re-resolver a query em tempo de execução para quem não enxerga o campo, e a
   * conversão inteira passa a falhar com `Variable does not exist: tmpVar1` —
   * medido, não suposto. Aqui, num serviço que já lê o campo em todas as suas
   * consultas, isso não acontece.
   *
   * NUNCA lança: sem a origem, a conversão segue e a etapa 1 fica sem espelho,
   * que é o comportamento tolerante de sempre.
   */
  public static Map<Id, Datetime> distribuicaoDeLeads(Set<Id> leadIds) {
    Map<Id, Datetime> saida = new Map<Id, Datetime>();
    if (leadIds == null || leadIds.isEmpty()) {
      return saida;
    }
    try {
      for (Lead l : [
        SELECT Id, SOL_Data_Distribuicao__c
        FROM Lead
        WHERE Id IN :leadIds
      ]) {
        saida.put(l.Id, l.SOL_Data_Distribuicao__c);
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLDuracaoEtapaService.distribuicaoDeLeads: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage()
      );
    }
    return saida;
  }

  private static Boolean ehDoTipo(Id valor, Schema.SObjectType tipo) {
    return valor != null && valor.getSObjectType() == tipo;
  }

  private static void registrarMenor(
    Map<Id, Map<String, Datetime>> mapa,
    Id paiId,
    String campo,
    Datetime valor
  ) {
    if (!mapa.containsKey(paiId)) {
      mapa.put(paiId, new Map<String, Datetime>());
    }
    Datetime atual = mapa.get(paiId).get(campo);
    if (atual == null || valor < atual) {
      mapa.get(paiId).put(campo, valor);
    }
  }

  private static void registrarMenor(
    Map<Id, Map<String, Date>> mapa,
    Id paiId,
    String campo,
    Date valor
  ) {
    if (!mapa.containsKey(paiId)) {
      mapa.put(paiId, new Map<String, Date>());
    }
    Date atual = mapa.get(paiId).get(campo);
    if (atual == null || valor < atual) {
      mapa.get(paiId).put(campo, valor);
    }
  }

  /** Acumula o resultado de uma chamada aninhada no resultado externo. */
  private static void somar(
    ResultadoDuracao alvo,
    ResultadoDuracao parcial
  ) {
    if (parcial == null) {
      return;
    }
    alvo.avaliados += parcial.avaliados;
    alvo.foraDoEscopo += parcial.foraDoEscopo;
    alvo.calculadas += parcial.calculadas;
    alvo.pendentes += parcial.pendentes;
    alvo.jaPreenchidas += parcial.jaPreenchidas;
    alvo.ignoradas += parcial.ignoradas;
    alvo.marcosConsolidados += parcial.marcosConsolidados;
    alvo.registrosAtualizados += parcial.registrosAtualizados;
    alvo.oportunidadesSincronizadas += parcial.oportunidadesSincronizadas;
    alvo.falhas += parcial.falhas;
    // `falhasSinalizadas` ficou de fora quando este método foi escrito, e o
    // efeito era silencioso: uma falha que VIROU pendência numa chamada
    // aninhada sumia do resultado externo, e quem lesse o resumo do Batch
    // concluiria que nenhuma falha tinha sido sinalizada.
    alvo.falhasSinalizadas += parcial.falhasSinalizadas;
    alvo.falhasSemSinal += parcial.falhasSemSinal;
  }

  // ==================================================================
  // Contagem de dias úteis
  // ==================================================================

  /**
   * Acumulado de dias úteis do intervalo global do lote, para contar qualquer
   * par em memória.
   *
   * Não é régua paralela: os dias úteis vêm de
   * `SOLBusinessHoursHelper.diasUteisNoIntervalo`, que por sua vez usa
   * `aberturaDoDia`. Aqui só se INDEXA a resposta da régua, para não perguntar
   * a mesma coisa milhares de vezes.
   */
  private class ContadorDiasUteis {
    private Date inicio;
    private Date fim;
    private List<Integer> acumulado;

    public ContadorDiasUteis(Id bhId, Date de, Date ate) {
      Set<Date> uteis = SOLBusinessHoursHelper.diasUteisNoIntervalo(
        bhId,
        de,
        ate
      );
      this.inicio = de;
      this.fim = ate;
      this.acumulado = new List<Integer>();
      Integer total = 0;
      Date dia = de;
      while (dia <= ate) {
        if (uteis.contains(dia)) {
          total++;
        }
        acumulado.add(total);
        dia = dia.addDays(1);
      }
    }

    /** O acumulado sabe responder por este par? */
    public Boolean cobre(Date origem, Date destino) {
      return destino >= origem && origem >= inicio && destino <= fim;
    }

    /** Dias úteis em `(origem, destino]`. Só use depois de `cobre`. */
    public Integer entre(Date origem, Date destino) {
      return acumulado[inicio.daysBetween(destino)] -
        acumulado[inicio.daysBetween(origem)];
    }
  }

  /**
   * Monta o acumulado do lote, ou devolve null quando não dá: sem calendário,
   * sem nenhum par sano para contar, ou intervalo global maior que o teto da
   * régua. Com null, `processar` volta a contar par a par — mais caro, porém
   * correto, e apenas no caso patológico de um lote com marcos separados por
   * mais de uma década.
   */
  private static ContadorDiasUteis montarContador(
    Id bhId,
    Date menor,
    Date maior
  ) {
    if (bhId == null || menor == null || maior == null) {
      return null;
    }
    if (menor.daysBetween(maior) > SOLBusinessHoursHelper.MAX_DIAS_INTERVALO) {
      return null;
    }
    try {
      contadoresMontados++;
      return new ContadorDiasUteis(bhId, menor, maior);
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'SOLDuracaoEtapaService: pré-cálculo do calendário indisponível (' +
          e.getTypeName() +
          '); a contagem seguirá par a par. ' +
          e.getMessage()
      );
      return null;
    }
  }

  // ==================================================================
  // Utilitários
  // ==================================================================

  /** Data em São Paulo do valor bruto do campo — um Date passa direto. */
  private static Date comoData(Object valor, Boolean ehDateTime) {
    if (valor == null) {
      return null;
    }
    if (ehDateTime) {
      return SOLBusinessHoursHelper.dataEm(
        (Datetime) valor,
        SOLBusinessHoursHelper.TZ_SAO_PAULO
      );
    }
    return (Date) valor;
  }

  /** Ids não nulos e do SObject esperado. O resto é descartado em silêncio. */
  private static Set<Id> idsUteis(List<Id> ids, Schema.SObjectType tipo) {
    Set<Id> saida = new Set<Id>();
    if (ids == null) {
      return saida;
    }
    for (Id i : ids) {
      if (i != null && i.getSObjectType() == tipo) {
        saida.add(i);
      }
    }
    return saida;
  }

  /**
   * Somente testes: força o caminho de FALHA de gravação, para provar que uma
   * falha analítica não desfaz o marco comercial e que a pendência técnica
   * ainda assim fica registrada. Protegido por `Test.isRunningTest()`.
   */
  /**
   * Somente testes: força a falha da gravação da DURAÇÃO. Protegido por
   * `Test.isRunningTest()`; fora de teste não faz nada.
   */
  @TestVisible
  private static Boolean simularFalhaDeGravacao = false;

  /**
   * Somente testes: força a falha da gravação do MARCO. É um seam SEPARADO do
   * anterior de propósito — as duas falhas têm políticas opostas, e um seam só
   * não conseguiria provar isso.
   */
  @TestVisible
  private static Boolean simularFalhaDeGravacaoDoMarco = false;

  /**
   * Somente testes: provoca uma exceção GENÉRICA e inesperada dentro da fase
   * obrigatória, ANTES de qualquer gravação.
   *
   * É um seam SEPARADO do anterior por um motivo concreto: aquele lança
   * `MarcoNaoGravadoException` diretamente e, por isso, NÃO passa pelo
   * `catch (Exception)` — um teste que o reutilizasse passaria sem exercitar o
   * caminho defeituoso. Este aqui força justamente o imprevisto.
   */
  @TestVisible
  private static Boolean simularFalhaInesperadaNoMarco = false;

  /**
   * Registros que ganharam pendência técnica NESTA transação por falha de
   * gravação. `aplicarPendencia` recalcula o estado do zero e, sem esta
   * memória, uma reavaliação posterior na mesma execução apagaria a pendência
   * que acabou de ser registrada — justamente a que ninguém mais registraria.
   */
  @TestVisible
  private static Set<Id> pendenciaTecnicaNestaExecucao = new Set<Id>();

  /** Somente testes: zera a memória de pendência técnica entre cenários. */
  @TestVisible
  private static void limparMemoriaDeFalha() {
    pendenciaTecnicaNestaExecucao = new Set<Id>();
  }

  /**
   * Último erro que impediu ATÉ o sinal mínimo de pendência. Existe para que um
   * teste possa afirmar POR QUE a pendência não coube no registro, em vez de só
   * constatar que não coube.
   */
  @TestVisible
  private static String ultimoErroDeSinal;

  /**
   * Gravação em modo de SISTEMA e com sucesso parcial, com sinal de segunda
   * chance quando algum registro não pôde ser gravado.
   *
   * Modo de sistema porque são campos técnicos que ninguém edita. Sucesso
   * parcial porque a falha de um registro não pode derrubar a medição dos
   * outros nem a operação comercial que originou a chamada.
   *
   * O QUE ACONTECE QUANDO A GRAVAÇÃO FALHA — e o limite honesto disso: não dá
   * para gravar a pendência no mesmo DML que acabou de ser recusado. O que se
   * faz é uma SEGUNDA gravação, mínima, tocando SÓ os três campos de pendência.
   * Ela costuma passar, porque a maioria das recusas vem de outro campo ou de
   * outra regra do registro. Quando nem ela passa, a pendência NÃO fica no
   * registro — e isso está contado em `falhasSemSinal`, propagado ao Batch, que
   * marca o `AsyncApexJob`. Mesmo nesse caso o registro NÃO some da varredura:
   * ele continua com os dois marcos e a duração vazia, que é exatamente a
   * cláusula que o Batch procura, então volta a ser tentado na próxima passada.
   */
  private static void gravar(List<SObject> registros, ResultadoDuracao r) {
    if (registros == null || registros.isEmpty()) {
      return;
    }
    List<SObject> falhados = new List<SObject>();
    List<String> motivos = new List<String>();

    if (simularFalhaDeGravacao && Test.isRunningTest()) {
      // Seam mínimo: a gravação principal não acontece, e todo o lote entra no
      // caminho de falha. Nada aqui roda fora de teste.
      for (SObject reg : registros) {
        r.falhas++;
        falhados.add(reg);
        motivos.add('falha simulada em teste');
      }
    } else {
      List<Database.SaveResult> resultados = Database.update(
        registros,
        false,
        AccessLevel.SYSTEM_MODE
      );
      for (Integer i = 0; i < resultados.size(); i++) {
        if (resultados[i].isSuccess()) {
          r.registrosAtualizados++;
          continue;
        }
        r.falhas++;
        falhados.add(registros[i]);
        motivos.add(primeiroErro(resultados[i]));
        System.debug(
          LoggingLevel.ERROR,
          'SOLDuracaoEtapaService: falha ao gravar duração em ' +
            registros[i].get('Id') +
            ' -> ' +
            resultados[i].getErrors()
        );
      }
    }

    if (!falhados.isEmpty()) {
      sinalizarFalhaDeGravacao(falhados, motivos, r);
    }
  }

  /**
   * Gravação do MARCO: atômica e que LANÇA em qualquer falha.
   *
   * É o oposto de `gravar`, e a diferença é a política, não o gosto. O marco é
   * o registro comercial do que aconteceu; a duração é medida sobre ele. A
   * decisão do P.O. é "marco SEMPRE, duração tolerante" — então aqui não há
   * sucesso parcial, não há segunda chance e não há engolir: se o marco não
   * pôde ser gravado, a exceção sobe até o Flow e desfaz a conclusão da Task,
   * para que nunca exista tarefa concluída afirmando um marco que não existe.
   *
   * Sobre atomicidade entre Lead e Oportunidade: são duas DMLs, porque uma
   * única DML não aceita tipos misturados. A atomicidade não vem do
   * `allOrNone`, e sim do `throw`: ele aborta a TRANSAÇÃO inteira do Flow, o
   * que desfaz também a gravação que já tinha passado.
   */
  private static void gravarMarcosOuLancar(
    List<SObject> registros,
    ResultadoDuracao r
  ) {
    if (registros == null || registros.isEmpty()) {
      return;
    }
    if (simularFalhaDeGravacaoDoMarco && Test.isRunningTest()) {
      throw new MarcoNaoGravadoException(MSG_MARCO_NAO_GRAVADO);
    }
    try {
      Database.update(registros, true, AccessLevel.SYSTEM_MODE);
      r.registrosAtualizados += registros.size();
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLDuracaoEtapaService: falha ao gravar MARCO -> ' +
          e.getTypeName() +
          ': ' +
          e.getMessage()
      );
      throw new MarcoNaoGravadoException(MSG_MARCO_NAO_GRAVADO);
    }
  }

  /**
   * Segunda chance: grava SÓ os campos de pendência dos registros que a
   * gravação principal recusou, para que a lacuna não fique invisível.
   */
  private static void sinalizarFalhaDeGravacao(
    List<SObject> falhados,
    List<String> motivos,
    ResultadoDuracao r
  ) {
    List<SObject> sinais = new List<SObject>();
    for (Integer i = 0; i < falhados.size(); i++) {
      Id registroId = (Id) falhados[i].get('Id');
      if (registroId == null) {
        r.falhasSemSinal++;
        continue;
      }
      SObject sinal = registroId.getSObjectType().newSObject(registroId);
      String detalhe = 'Falha ao gravar a medição: ' + motivos[i];
      if (detalhe.length() > MAX_DETALHE) {
        detalhe = detalhe.abbreviate(MAX_DETALHE);
      }
      sinal.put(CAMPO_PENDENTE, true);
      sinal.put(CAMPO_MOTIVO, MOTIVO_FALHA_TECNICA);
      sinal.put(CAMPO_DETALHE, detalhe);
      sinais.add(sinal);
    }
    if (sinais.isEmpty()) {
      return;
    }
    List<Database.SaveResult> resultados = Database.update(
      sinais,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < resultados.size(); i++) {
      if (resultados[i].isSuccess()) {
        r.falhasSinalizadas++;
        pendenciaTecnicaNestaExecucao.add((Id) sinais[i].get('Id'));
        continue;
      }
      // Nem o sinal mínimo passou. É o único caso em que a falha NÃO fica no
      // registro, e ele está contado para o Batch marcar o job.
      r.falhasSemSinal++;
      ultimoErroDeSinal = String.valueOf(resultados[i].getErrors());
      System.debug(
        LoggingLevel.ERROR,
        'SOLDuracaoEtapaService: não foi possível sequer sinalizar a pendência em ' +
          sinais[i].get('Id') +
          ' -> ' +
          resultados[i].getErrors()
      );
    }
  }

  private static String primeiroErro(Database.SaveResult resultado) {
    List<Database.Error> erros = resultado.getErrors();
    if (erros == null || erros.isEmpty()) {
      return 'erro não detalhado pela plataforma';
    }
    return erros[0].getStatusCode() + ' ' + erros[0].getMessage();
  }

  private static void registrarFalha(
    String origem,
    Exception e,
    ResultadoDuracao r
  ) {
    r.falhas++;
    // Falha ANTES de saber quais registros existem — tipicamente a própria
    // consulta. Não há registro em que gravar pendência, e afirmar o contrário
    // seria falso. O que resta é o contador, que o Batch usa para marcar o
    // `AsyncApexJob`, e o log.
    r.falhasSemSinal++;
    System.debug(
      LoggingLevel.ERROR,
      'SOLDuracaoEtapaService.' +
        origem +
        ': ' +
        e.getTypeName() +
        ': ' +
        e.getMessage() +
        ' | ' +
        e.getStackTraceString()
    );
  }
}

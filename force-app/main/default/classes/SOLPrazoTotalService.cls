/**
 * CLICKUP-9424 — Card 13 — Reatribuição automática por estouro do prazo total
 * de 30 dias.
 *
 * A régua é a MESMA dos demais prazos da jornada (PDF: "os '30 dias' devem
 * seguir a mesma régua dos demais prazos deste processo"): 30 dias ÚTEIS por
 * SOLBusinessHoursHelper — calendário oficial da org, feriados e timezone
 * America/Sao_Paulo. Nada de dias corridos, nada de grade fixa seg–sex.
 *
 * ORIGEM DO PRAZO: Opportunity.SOL_Data_Inicio_Ciclo_Comercial__c, que
 * SOL_ConverterLead copia de Lead.SOL_Data_Contato_Efetivado__c na conversão.
 * O limite fica em Opportunity.SOL_Prazo_Total_Comercial__c. NENHUM dos dois é
 * recalculado a partir de CreatedDate, mudança de etapa ou reatribuição — este
 * serviço apenas LÊ os dois campos. Sem data de início não há inferência
 * silenciosa: a Oportunidade é simplesmente ignorada.
 *
 * QUANDO O PRAZO VENCE e a Oportunidade continua ABERTA (Ganho e Perdido têm
 * IsClosed = true e nunca entram), para Record Type SOL e produto
 * "Recuperação Tributária" ou "ART 360":
 *  - transfere a Oportunidade ao próximo vendedor elegível da Fila_Leads_SOL,
 *    EXCLUINDO o proprietário atual da escolha;
 *  - transfere ao novo vendedor todas as Tasks ainda ABERTAS da Oportunidade
 *    (IsClosed = false); Tasks concluídas/canceladas ficam intactas;
 *  - registra data, motivo e quantidade da reatribuição;
 *  - roda UMA única vez por Oportunidade (SOL_Qtd_Reatribuicoes_Prazo__c > 0
 *    marca como processada);
 *  - preserva etapa, campos, datas, marcos e histórico — não cria tarefas nem
 *    reinicia prazos.
 *
 * O vendedor anterior CONTINUA na rotação de novos Leads: nada é removido da
 * fila; só o ponteiro global avança.
 *
 * SEM OUTRO VENDEDOR ATIVO: o proprietário NÃO é alterado e a Oportunidade NÃO
 * é marcada como processada (a contagem não é incrementada). Fica registrada a
 * situação controlada em SOL_Status_Reatribuicao_Prazo__c = "Sem outro
 * vendedor" — mas SÓ quando status/motivo ainda não estão nesse valor, para não
 * gerar uma gravação idêntica a cada varredura. A próxima execução do Batch
 * tenta de novo.
 *
 * REAPROVEITA a fila, o roster de usuários diretos ativos, o ponteiro global e a
 * seleção round-robin de SOLDistribuicaoService (bloquearSingleton,
 * localizarFilaValida, obterMembrosDiretosAtivos, indiceDe,
 * proximoVendedorExcluindo) — o algoritmo NÃO é duplicado. Respeita o
 * kill-switch do singleton (Ativo__c = false ⇒ nada é tocado).
 *
 * ATOMICIDADE POR OPORTUNIDADE (revisão do PR #15): cada Oportunidade é gravada
 * dentro do SEU PRÓPRIO Savepoint, e o bloco inclui QUATRO passos —
 * proprietário, Tasks abertas, auditoria e o PONTEIRO GLOBAL do round-robin.
 * Só depois de todos os quatro a reatribuição é contada como sucesso. Se
 * qualquer um falhar, o rollback desfaz TUDO daquela Oportunidade (inclusive o
 * avanço do ponteiro), a contagem dela fica zerada, o cursor NÃO avança e
 * r.comErro é incrementado — o SOLPrazoTotalBatch converte isso em falha
 * visível do AsyncApexJob. As demais Oportunidades elegíveis seguem
 * reatribuídas normalmente e a que falhou volta na próxima varredura.
 *
 * Não existe estado intermediário "reatribuída mas ponteiro não avançado": com
 * o ponteiro dentro do Savepoint, uma Oportunidade reatribuída implica um
 * ponteiro coerente, e um ponteiro que não pôde ser gravado implica uma
 * Oportunidade intacta.
 *
 * CONCORRÊNCIA: o singleton é travado com FOR UPDATE (serializa com a
 * distribuição inicial e com a reatribuição por falta de contato); as
 * Oportunidades e as Tasks também são lidas com FOR UPDATE.
 *
 * VOLUME: o serviço faz SOQL/DML proporcional ao número de Oportunidades JÁ
 * VENCIDAS e ainda não reatribuídas de uma varredura — conjunto pequeno e
 * decrescente (cada uma sai do filtro após a 1ª reatribuição). O
 * SOLPrazoTotalScheduler dispara o Batch com lote = 1, então em produção cada
 * transação processa UMA Oportunidade. Chamadas diretas em massa (testes, E2E)
 * ficam muito abaixo dos limites de governança.
 *
 * NÃO altera proprietário de Conta nem de Contato. NÃO antecipa o CLICKUP-9425.
 */
public without sharing class SOLPrazoTotalService {
  /** Régua do prazo total: 30 dias ÚTEIS. */
  public static final Integer DIAS_UTEIS_PRAZO_TOTAL = 30;

  @TestVisible
  private static final String RECORD_TYPE_SOL = 'SOL';
  @TestVisible
  private static final String PRODUTO_RECUPERACAO = 'Recuperação Tributária';
  @TestVisible
  private static final String PRODUTO_ART = 'ART 360';
  @TestVisible
  private static final Set<String> PRODUTOS_NO_ESCOPO = new Set<String>{
    'Recuperação Tributária',
    'ART 360'
  };
  @TestVisible
  private static final String STATUS_REATRIBUIDO = 'Reatribuido';
  @TestVisible
  private static final String STATUS_SEM_OUTRO_VENDEDOR = 'Sem outro vendedor';

  /** Motivo registrado na Oportunidade reatribuída. */
  public static final String MOTIVO_PRAZO_TOTAL = 'Estouro do prazo total de 30 dias úteis do ciclo comercial';
  /** Situação controlada quando não há outro vendedor ativo na fila. */
  public static final String MOTIVO_SEM_OUTRO_VENDEDOR = 'Prazo total vencido, mas não havia outro vendedor ativo disponível na fila.';

  /** Mensagens controladas de falha (o Batch registra, não propaga ao usuário). */
  public static final String MSG_CONFIG = 'A reatribuição por prazo total está temporariamente indisponível (fila/estado). Acione o administrador.';
  public static final String MSG_ERRO_GENERICO = 'A reatribuição por prazo total não pôde ser concluída agora. As Oportunidades serão reavaliadas na próxima varredura.';

  /** Resultado controlado da varredura. */
  public class ResultadoPrazoTotal {
    /** Oportunidades que trocaram de proprietário agora. */
    public Integer reatribuidas = 0;
    /** Tasks abertas transferidas ao novo proprietário. */
    public Integer tarefasTransferidas = 0;
    /** Prazo vencido, mas sem outro vendedor ativo — não marcadas como processadas. */
    public Integer semOutroVendedor = 0;
    /** Fora de escopo, prazo não vencido, fechadas ou já processadas. */
    public Integer ignoradas = 0;
    /** Oportunidades que falharam na gravação (reavaliadas na próxima varredura). */
    public Integer comErro = 0;
    public List<String> mensagens = new List<String>();
  }

  /**
   * Limite de 30 dias ÚTEIS a partir de `inicio`, pela régua compartilhada.
   *
   * @throws SOLBusinessHoursHelper.CalendarioIndisponivelException calendário
   *   ausente/inativo. SOL_ConverterLead aborta a conversão inteira nesse caso —
   *   uma Oportunidade com contato efetivado NÃO pode nascer sem este prazo.
   */
  public static Datetime calcularPrazoTotal(Datetime inicio) {
    if (inicio == null) {
      return null;
    }
    return SOLBusinessHoursHelper.prazoEmDiasUteis(
      SOLBusinessHoursHelper.businessHoursId(),
      inicio,
      DIAS_UTEIS_PRAZO_TOTAL
    );
  }

  /**
   * Reatribui, em round-robin, as Oportunidades SOL cujo prazo total de 30 dias
   * úteis venceu e que continuam abertas.
   *
   * @param opportunityIds Ids candidatos (qualquer origem; filtrados aqui).
   * @return contagens controladas — nunca lança para o chamador; r.comErro > 0
   *   sinaliza que ao menos uma Oportunidade falhou (o Batch torna isso visível
   *   no AsyncApexJob).
   */
  public static ResultadoPrazoTotal reatribuirPorPrazoTotal(List<Id> opportunityIds) {
    ResultadoPrazoTotal r = new ResultadoPrazoTotal();
    if (opportunityIds == null || opportunityIds.isEmpty()) {
      return r;
    }

    Set<Id> ids = new Set<Id>();
    for (Id oid : opportunityIds) {
      if (oid != null && oid.getSObjectType() == Opportunity.SObjectType) {
        ids.add(oid);
      }
    }
    if (ids.isEmpty()) {
      return r;
    }

    Datetime agora = System.now();

    // --------------------------------------------------------------- fase 1
    // Trava do singleton, seleção das candidatas e do roster. Um problema de
    // configuração aqui (singleton ausente, fila inválida) é situação
    // controlada: nada foi tocado, devolve MSG_CONFIG.
    SOL_Distribuicao_Estado__c estado;
    List<Opportunity> candidatas = new List<Opportunity>();
    List<User> ativos;
    Integer cursor = 0;
    Integer n = 0;
    Savepoint spFase1 = Database.setSavepoint();
    try {
      // Mesmo lock da distribuição inicial e da reatribuição por falta de
      // contato: serializa o avanço do ponteiro entre transações concorrentes.
      estado = SOLDistribuicaoService.bloquearSingleton();

      List<Opportunity> carregadas = [
        SELECT
          Id,
          OwnerId,
          StageName,
          IsClosed,
          SOL_Produto_Negocio__c,
          RecordType.DeveloperName,
          SOL_Data_Inicio_Ciclo_Comercial__c,
          SOL_Prazo_Total_Comercial__c,
          SOL_Qtd_Reatribuicoes_Prazo__c,
          SOL_Status_Reatribuicao_Prazo__c,
          SOL_Motivo_Reatribuicao_Prazo__c
        FROM Opportunity
        WHERE Id IN :ids
        FOR UPDATE
      ];

      Set<Id> encontradas = new Set<Id>();
      for (Opportunity o : carregadas) {
        encontradas.add(o.Id);
        Boolean noEscopo =
          o.RecordType.DeveloperName == RECORD_TYPE_SOL &&
          PRODUTOS_NO_ESCOPO.contains(o.SOL_Produto_Negocio__c) &&
          // Ganho e Perdido têm IsClosed = true: nunca são reatribuídas.
          o.IsClosed == false &&
          // Sem data de início ou sem prazo calculado: nenhuma inferência.
          o.SOL_Data_Inicio_Ciclo_Comercial__c != null &&
          o.SOL_Prazo_Total_Comercial__c != null &&
          // No limite JÁ reatribui (<=), antes do limite não.
          o.SOL_Prazo_Total_Comercial__c <= agora &&
          // Uma única vez por Oportunidade.
          (o.SOL_Qtd_Reatribuicoes_Prazo__c == null ||
          o.SOL_Qtd_Reatribuicoes_Prazo__c <= 0);
        if (noEscopo) {
          candidatas.add(o);
        } else {
          r.ignoradas++;
        }
      }
      r.ignoradas += (ids.size() - encontradas.size());

      if (candidatas.isEmpty()) {
        return r;
      }

      // Kill-switch desligado: a reatribuição por prazo também para.
      if (!estado.Ativo__c) {
        r.ignoradas += candidatas.size();
        candidatas.clear();
        return r;
      }

      // Roster: mesmos membros diretos ativos da Fila_Leads_SOL.
      try {
        ativos = SOLDistribuicaoService.obterMembrosDiretosAtivos(
          SOLDistribuicaoService.localizarFilaValida().Id
        );
      } catch (SOLDistribuicaoService.RosterVazioException e) {
        ativos = new List<User>();
      }
      n = ativos.size();

      // Ponto de partida: o próximo após o ponteiro global (User.Id ASC).
      if (n > 0 && estado.Ultimo_Usuario__c != null) {
        Integer k = SOLDistribuicaoService.indiceDe(ativos, estado.Ultimo_Usuario__c);
        cursor = (k >= 0) ? Math.mod(k + 1, n) : 0;
      }
    } catch (SOLDistribuicaoService.DistribuicaoException e) {
      Database.rollback(spFase1);
      System.debug(LoggingLevel.ERROR, 'SOLPrazoTotalService (config): ' + e.getMessage());
      ResultadoPrazoTotal erro = new ResultadoPrazoTotal();
      erro.comErro = ids.size();
      erro.mensagens.add(MSG_CONFIG);
      return erro;
    } catch (Exception e) {
      Database.rollback(spFase1);
      System.debug(
        LoggingLevel.ERROR,
        'SOLPrazoTotalService (fase 1): ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      ResultadoPrazoTotal erro = new ResultadoPrazoTotal();
      erro.comErro = ids.size();
      erro.mensagens.add(MSG_ERRO_GENERICO);
      return erro;
    }

    // --------------------------------------------------------------- fase 2
    // Uma Oportunidade por vez, cada uma no SEU Savepoint. A falha de uma não
    // desfaz nem impede as outras.
    List<Opportunity> semVendedorParaGravar = new List<Opportunity>();

    for (Opportunity o : candidatas) {
      Id escolhido = n == 0
        ? null
        : SOLDistribuicaoService.proximoVendedorExcluindo(ativos, cursor, o.OwnerId);

      if (escolhido == null) {
        // Não altera proprietário e NÃO marca como processada. Só grava a
        // situação controlada quando ela AINDA NÃO está registrada — evita uma
        // gravação idêntica a cada varredura.
        Boolean jaRegistrada =
          o.SOL_Status_Reatribuicao_Prazo__c == STATUS_SEM_OUTRO_VENDEDOR &&
          o.SOL_Motivo_Reatribuicao_Prazo__c == MOTIVO_SEM_OUTRO_VENDEDOR;
        if (!jaRegistrada) {
          semVendedorParaGravar.add(
            new Opportunity(
              Id = o.Id,
              SOL_Status_Reatribuicao_Prazo__c = STATUS_SEM_OUTRO_VENDEDOR,
              SOL_Motivo_Reatribuicao_Prazo__c = MOTIVO_SEM_OUTRO_VENDEDOR
            )
          );
        }
        r.semOutroVendedor++;
        continue;
      }

      Integer proxCursor = Math.mod(SOLDistribuicaoService.indiceDe(ativos, escolhido) + 1, n);

      // Valores em memória do ponteiro ANTES desta Oportunidade: o rollback
      // desfaz o banco, mas não a instância `estado` que segue para a próxima
      // iteração — restaurar é obrigatório.
      Id ponteiroAnterior = estado.Ultimo_Usuario__c;
      Datetime dataPonteiroAnterior = estado.Data_Ultima_Distribuicao__c;

      Savepoint spOpp = Database.setSavepoint();
      try {
        update new Opportunity(
          Id = o.Id,
          OwnerId = escolhido,
          SOL_Qtd_Reatribuicoes_Prazo__c =
            (o.SOL_Qtd_Reatribuicoes_Prazo__c == null
              ? 0
              : o.SOL_Qtd_Reatribuicoes_Prazo__c) + 1,
          SOL_Data_Reatribuicao_Prazo__c = agora,
          SOL_Motivo_Reatribuicao_Prazo__c = MOTIVO_PRAZO_TOTAL,
          SOL_Status_Reatribuicao_Prazo__c = STATUS_REATRIBUIDO
        );
        // Etapa, marcos, datas e o próprio prazo NÃO são tocados.

        // Tasks ABERTAS desta Oportunidade. Concluídas/canceladas (IsClosed =
        // true) ficam intactas. All-or-none: dentro do escopo de UMA Opp, ou
        // todas as Tasks vão junto com o proprietário, ou a Opp inteira volta.
        List<Task> abertas = [
          SELECT Id, OwnerId
          FROM Task
          WHERE WhatId = :o.Id AND IsClosed = false
          FOR UPDATE
        ];
        List<Task> transferir = new List<Task>();
        for (Task t : abertas) {
          if (t.OwnerId != escolhido) {
            transferir.add(new Task(Id = t.Id, OwnerId = escolhido));
          }
        }
        if (!transferir.isEmpty()) {
          update transferir;
        }

        // PONTEIRO NO MESMO SAVEPOINT (revisão final do PR #15). Se o ponteiro
        // não puder ser gravado, o round-robin ficaria incorreto com a
        // Oportunidade já reatribuída — então a Oportunidade, as Tasks, a
        // auditoria e o ponteiro são tudo ou nada.
        if (escolhido != estado.Ultimo_Usuario__c) {
          estado.Ultimo_Usuario__c = escolhido;
          estado.Data_Ultima_Distribuicao__c = agora;
          gravarPonteiro(estado);
        }

        // Só AGORA a reatribuição conta como sucesso.
        r.reatribuidas++;
        r.tarefasTransferidas += transferir.size();
        cursor = proxCursor;
      } catch (Exception e) {
        // Desfaz APENAS esta Oportunidade — proprietário, Tasks, auditoria E
        // ponteiro. As demais seguem. A Opp fica elegível para a próxima
        // varredura (contagem intacta) e o cursor NÃO avança.
        Database.rollback(spOpp);
        estado.Ultimo_Usuario__c = ponteiroAnterior;
        estado.Data_Ultima_Distribuicao__c = dataPonteiroAnterior;
        r.comErro++;
        r.mensagens.add('Oportunidade ' + o.Id + ': ' + e.getMessage());
        System.debug(
          LoggingLevel.ERROR,
          'SOLPrazoTotalService: falha ao reatribuir a Oportunidade ' +
            o.Id +
            ': ' +
            e.getMessage() +
            '\n' +
            e.getStackTraceString()
        );
      }
    }

    // Situações controladas (sem outro vendedor) que mudaram de valor.
    if (!semVendedorParaGravar.isEmpty()) {
      Savepoint spSem = Database.setSavepoint();
      try {
        update semVendedorParaGravar;
      } catch (Exception e) {
        Database.rollback(spSem);
        r.comErro++;
        r.mensagens.add('Falha ao registrar "sem outro vendedor": ' + e.getMessage());
        System.debug(LoggingLevel.ERROR, 'SOLPrazoTotalService (sem vendedor): ' + e.getMessage());
      }
    }

    return r;
  }

  /**
   * Somente testes: força a falha da gravação do ponteiro para comprovar que a
   * Oportunidade, as Tasks, a auditoria e o ponteiro são tudo ou nada. Não há
   * como derrubar só este DML por dados (o singleton não tem Validation Rule
   * nem lookup filter), então a injeção é explícita e blindada por
   * `Test.isRunningTest()`.
   */
  @TestVisible
  private static Boolean falharGravacaoDoPonteiro = false;

  /** Gravação do ponteiro global. Isolada só para permitir a injeção de falha. */
  private static void gravarPonteiro(SOL_Distribuicao_Estado__c estado) {
    if (Test.isRunningTest() && falharGravacaoDoPonteiro) {
      throw new PonteiroException(
        'Falha simulada na gravação do ponteiro global (somente testes).'
      );
    }
    update estado;
  }

  /** Falha na gravação do ponteiro global do round-robin. */
  public class PonteiroException extends Exception {
  }
}

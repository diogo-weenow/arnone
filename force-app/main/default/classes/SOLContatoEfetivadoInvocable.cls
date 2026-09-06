/**
 * CLICKUP-9417 — Entrada da sinalização de contato efetivado + cancelamento das
 * tarefas de contato pendentes.
 *
 * Camada fina entre o Record-Triggered Flow SOL_Contato_Efetivado (after-save em
 * Task) e SOLDistribuicaoService.registrarContatoEfetivado. NÃO duplica lógica,
 * não faz SOQL nem DML.
 *
 * Tratamento de falha ATÔMICO (ajuste do PR #5): se o cancelamento não puder
 * ser concluído, a exceção controlada é RELANÇADA para o Flow. Isso aborta a
 * transação inteira — a própria conclusão da Task é desfeita — em vez de
 * deixar a Task concluída e o Lead/tarefas pendentes sem atualizar. O vendedor
 * recebe a mensagem controlada e conclui a tarefa de novo. Detalhe técnico só
 * no log de debug.
 *
 * Mesmo comportamento em teste e em produção.
 */
public with sharing class SOLContatoEfetivadoInvocable {
  /**
   * (CLICKUP-9447) Mensagem controlada da porta ESTRITA. Sem detalhe técnico:
   * o vendedor precisa saber que nada foi salvo e por quê, em linguagem de
   * negócio.
   */
  public static final String MSG_VINCULO_INVALIDO = 'Não foi possível registrar a resposta: esta tarefa não está vinculada a um lead da Arnone Soluções. Nenhuma alteração foi salva.';

  /**
   * (CLICKUP-9449) Mensagem controlada do lead em ESTADO TERMINAL — negócio
   * perdido ou opt-out já registrado. Também sem detalhe técnico.
   */
  public static final String MSG_LEAD_NAO_ELEGIVEL = 'Não foi possível registrar o contato efetivado: este lead não está mais em contato ativo (negócio perdido ou opt-out registrado). Nenhuma alteração foi salva.';

  public class Entrada {
    @InvocableVariable(
      label='Id do Lead (WhoId da Task)'
      description='Lead cujo contato foi efetivado.'
      required=true
    )
    public Id leadId;

    /**
     * (CLICKUP-9447) Porta ESTRITA, usada apenas pelo Flow
     * SOL_Contato_Efetivado_Por_Envio.
     *
     * Sem ela, uma referência que não seja Lead da Arnone Soluções era
     * simplesmente IGNORADA — e no caminho do checkbox isso deixava um dado
     * FALSO gravado: a tarefa afirmando que o lead respondeu, sem lead nenhum
     * efetivado. Com ela, a entrada inválida derruba a transação inteira e o
     * checkbox não persiste.
     *
     * O caminho da LIGAÇÃO (CLICKUP-9417) não informa este campo e mantém o
     * comportamento tolerante de sempre: lá o resultado "Atendeu" é o registro,
     * e ignorar um WhoId de Contact nunca gravou nada falso.
     */
    @InvocableVariable(
      label='Exigir vínculo com Lead da Arnone Soluções'
      description='Quando verdadeiro, uma referência que não seja Lead SOL ativo faz a operação inteira falhar em vez de ser ignorada.'
      required=false
    )
    public Boolean estrito;
  }

  @InvocableMethod(
    label='Registrar contato efetivado SOL (cancela tarefas pendentes)'
    description='Consolida os Ids recebidos e chama SOLDistribuicaoService.registrarContatoEfetivado uma única vez por execução bulk.'
    category='Arnone Soluções'
  )
  public static void registrar(List<Entrada> entradas) {
    if (entradas == null || entradas.isEmpty()) {
      return;
    }

    Set<Id> ids = new Set<Id>();
    Boolean estrito = false;
    Boolean houveReferenciaInvalida = false;
    for (Entrada entrada : entradas) {
      if (entrada == null) {
        continue;
      }
      if (entrada.estrito == true) {
        estrito = true;
      }
      if (
        entrada.leadId != null &&
        entrada.leadId.getSObjectType() == Lead.SObjectType
      ) {
        ids.add(entrada.leadId);
      } else {
        houveReferenciaInvalida = true;
      }
    }

    // (CLICKUP-9447) Na porta estrita, qualquer referência fora do escopo
    // derruba a transação — inclusive quando o resto do lote é válido. É o que
    // impede um lote misto de terminar pela metade, com a tarefa inválida
    // marcada e nenhum lead efetivado por ela.
    if (estrito) {
      exigirLeadsSOL(ids, houveReferenciaInvalida);
    }

    if (ids.isEmpty()) {
      return;
    }

    try {
      SOLDistribuicaoService.ResultadoContatoEfetivado r = SOLDistribuicaoService.registrarContatoEfetivado(
        new List<Id>(ids)
      );

      // (CLICKUP-9449) Na porta ESTRITA, um Lead que o serviço RECUSOU não pode
      // terminar com a marcação gravada. Sem isto, marcar
      // `SOL_Contato_Efetivado__c` num Lead perdido ou em opt-out deixava o flag
      // verdadeiro, sem contato registrado e com a data vazia — o serviço
      // ignorava e ninguém desfazia a gravação original. "O Apex ignora" não é
      // proteção; é dado falso persistido.
      //
      // A decisão vem do resultado do SERVIÇO, que avalia o Lead lido com
      // FOR UPDATE — não da pré-consulta sem lock feita em `exigirLeadsSOL`.
      // Como aquela pré-consulta já rejeitou o que não é Lead SOL ativo, um
      // `ignorados > 0` aqui só pode ser estado terminal.
      //
      // A porta TOLERANTE (ligação, sem `estrito`) não passa por aqui e mantém
      // o comportamento de sempre: ignora em silêncio e a Task conclui.
      if (estrito && r != null && r.ignorados > 0) {
        throw new SOLDistribuicaoService.ContatoEfetivadoException(
          MSG_LEAD_NAO_ELEGIVEL
        );
      }
    } catch (SOLDistribuicaoService.ContatoEfetivadoException e) {
      // Falha já tratada e com Savepoint desfeito no serviço: relança a
      // mensagem controlada para o Flow abortar a transação inteira.
      System.debug(LoggingLevel.ERROR, 'SOLContatoEfetivadoInvocable: ' + e.getMessage());
      throw e;
    } catch (Exception e) {
      // Qualquer outra falha inesperada: também aborta a transação, com
      // mensagem controlada (nunca detalhe técnico ao vendedor).
      System.debug(
        LoggingLevel.ERROR,
        'SOLContatoEfetivadoInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLDistribuicaoService.ContatoEfetivadoException(
        SOLDistribuicaoService.MSG_CONTATO_EFETIVADO_FALHA
      );
    }
  }

  /**
   * (CLICKUP-9447) Porta estrita: TODAS as referências recebidas têm de ser
   * Leads da Arnone Soluções ainda não convertidos. Qualquer desvio derruba a
   * transação com mensagem controlada, e o save que originou a chamada — a
   * marcação do checkbox — é desfeito junto.
   *
   * O Record Type é verificado aqui, e não em Validation Rule, porque o WhoId
   * é polimórfico: uma fórmula não alcança com segurança o Record Type do
   * registro apontado. A checagem é uma consulta única para o lote inteiro.
   */
  private static void exigirLeadsSOL(
    Set<Id> ids,
    Boolean houveReferenciaInvalida
  ) {
    if (houveReferenciaInvalida || ids.isEmpty()) {
      throw new SOLDistribuicaoService.ContatoEfetivadoException(
        MSG_VINCULO_INVALIDO
      );
    }
    Set<Id> elegiveis = new Set<Id>();
    for (Lead l : [
      SELECT Id
      FROM Lead
      WHERE
        Id IN :ids
        AND RecordType.DeveloperName = :SOLDistribuicaoService.RECORD_TYPE_DEVELOPER_NAME
        AND IsConverted = FALSE
    ]) {
      elegiveis.add(l.Id);
    }
    if (elegiveis.size() != ids.size()) {
      throw new SOLDistribuicaoService.ContatoEfetivadoException(
        MSG_VINCULO_INVALIDO
      );
    }
  }
}

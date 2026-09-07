/**
 * CLICKUP-9425 — Entrada da PERDA na Oportunidade (depois da conversão).
 *
 * Camada fina entre o Record-Triggered Flow
 * SOL_Encerrar_Tarefas_Oportunidade_Perdida (after-save em Opportunity) e
 * SOLNegocioPerdidoService.encerrarPorOportunidadePerdida. NÃO duplica lógica,
 * não faz SOQL nem DML.
 *
 * Automação SEPARADA da do Lead de propósito: objetos diferentes, gatilhos
 * diferentes, entradas diferentes no serviço.
 *
 * (CLICKUP-9438) Passou a receber também a ETAPA ANTERIOR — o Flow envia
 * `$Record__Prior.StageName`, isto é, o estado ANTES do save que fechou o
 * negócio. É o único ponto da plataforma em que esse valor ainda existe: o
 * after-save já vê "Perdido" no registro, e o Field History não junta etapa e
 * motivo numa mesma linha de relatório. Sem ela o serviço aborta a perda em vez
 * de registrar a ocorrência com a etapa errada.
 *
 * Falha ATÔMICA: se o cancelamento das Tasks ou o registro da ocorrência
 * falhar, a exceção controlada é RELANÇADA para o Flow. Com
 * flowTransactionModel = CurrentTransaction, isso aborta a própria mudança da
 * Oportunidade para "Perdido".
 */
public with sharing class SOLNegocioPerdidoOportunidadeInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id da Oportunidade'
      description='Oportunidade que virou "Perdido".'
      required=true
    )
    public Id opportunityId;

    @InvocableVariable(
      label='Etapa anterior à perda'
      description='Etapa de onde a Oportunidade saiu, vinda de $Record__Prior.StageName. Obrigatória: é o que o relatório de perdas por etapa consome, e depois do save ela não existe mais em lugar nenhum.'
      required=true
    )
    public String etapaAnterior;
  }

  @InvocableMethod(
    label='Encerrar tarefas da Oportunidade perdida SOL'
    description='Consolida os Ids recebidos e chama SOLNegocioPerdidoService.encerrarPorOportunidadePerdida uma única vez por execução bulk, levando a etapa anterior de cada Oportunidade.'
    category='Arnone Soluções'
  )
  public static void encerrar(List<Entrada> entradas) {
    if (entradas == null || entradas.isEmpty()) {
      return;
    }

    // Consolidação bulk: uma chamada só ao serviço, com a etapa anterior de
    // cada Oportunidade. A PRIMEIRA etapa informada para um mesmo Id vence —
    // num lote a mesma Oportunidade só aparece uma vez, e repetição com valores
    // divergentes seria defeito do chamador, não dado a ser mesclado.
    Map<Id, String> etapasAnteriores = new Map<Id, String>();
    for (Entrada entrada : entradas) {
      if (
        entrada != null &&
        entrada.opportunityId != null &&
        entrada.opportunityId.getSObjectType() == Opportunity.SObjectType &&
        !etapasAnteriores.containsKey(entrada.opportunityId)
      ) {
        etapasAnteriores.put(entrada.opportunityId, entrada.etapaAnterior);
      }
    }
    if (etapasAnteriores.isEmpty()) {
      return;
    }

    try {
      SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
        new List<Id>(etapasAnteriores.keySet()),
        etapasAnteriores
      );
    } catch (SOLNegocioPerdidoService.NegocioPerdidoException e) {
      System.debug(LoggingLevel.ERROR, 'SOLNegocioPerdidoOportunidadeInvocable: ' + e.getMessage());
      throw e;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLNegocioPerdidoOportunidadeInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLNegocioPerdidoService.NegocioPerdidoException(
        SOLNegocioPerdidoService.MSG_FALHA_OPORTUNIDADE
      );
    }
  }
}

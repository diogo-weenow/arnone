/**
 * Migração (backfill) do produto SINGLE (DEPRECADO) para o MULTI-SELECT novo da
 * Arnone Soluções:
 *   - Lead:        SOL_Produto_Interesse__c  -> SOL_Produtos_Interesse__c
 *   - Opportunity: SOL_Produto_Negocio__c    -> SOL_Produtos_Negocio__c
 *
 * Copia o valor único existente para o novo campo (o valor único é uma seleção
 * única válida no multi-select restrito, com os mesmos valores). Roda UMA vez
 * após o deploy, uma instância por objeto:
 *   Database.executeBatch(new SOLProdutoBackfillBatch('Lead'));
 *   Database.executeBatch(new SOLProdutoBackfillBatch('Opportunity'));
 *
 * IDEMPOTENTE: só grava onde o campo NOVO está vazio e o ANTIGO preenchido.
 * Reexecutar não reescreve o que já foi migrado nem sobrescreve edição posterior
 * no campo novo. Bulk-safe: zero SOQL/DML em laço.
 *
 * `without sharing` + contexto de sistema do batch: a migração enxerga e grava
 * todos os registros SOL independentemente de sharing/FLS do usuário que dispara.
 */
public without sharing class SOLProdutoBackfillBatch implements Database.Batchable<SObject> {
  @TestVisible
  private final String objeto;
  @TestVisible
  private final String campoAntigo;
  @TestVisible
  private final String campoNovo;
  /**
   * false (padrão) = só registros ATIVOS. true = só registros TERMINAIS (Opp
   * fechada / Lead convertido) — rodar SOMENTE com os flows terminais
   * desativados (ver runbook), senão marcos/perdas re-disparam.
   */
  @TestVisible
  private final Boolean terminais;

  public class BackfillException extends Exception {
  }

  public SOLProdutoBackfillBatch(String objeto) {
    this(objeto, false);
  }

  public SOLProdutoBackfillBatch(String objeto, Boolean terminais) {
    this.terminais = terminais == true;
    this.objeto = objeto;
    if (objeto == 'Lead') {
      this.campoAntigo = 'SOL_Produto_Interesse__c';
      this.campoNovo = 'SOL_Produtos_Interesse__c';
    } else if (objeto == 'Opportunity') {
      this.campoAntigo = 'SOL_Produto_Negocio__c';
      this.campoNovo = 'SOL_Produtos_Negocio__c';
    } else {
      throw new BackfillException(
        'Objeto não suportado pelo backfill de produto: ' + objeto
      );
    }
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    // SÓ REGISTROS ATIVOS. Setar o produto num registro TERMINAL (Opp fechada /
    // Lead convertido) re-dispara os flows de marco/perda/encerramento (critério
    // produto+etapa vai de false->true), que NÃO são idempotentes e duplicariam
    // contadores/eventos de perda. Registros ativos são exatamente os que a
    // lógica viva do funil precisa do campo novo; os terminais mantêm o campo
    // antigo e devem ser migrados numa janela com esses flows desativados
    // (ver runbook). O recorte "novo vazio" fica no execute (semântica de null
    // do multi-select em SOQL).
    String filtroAtivo = (objeto == 'Lead')
      ? (terminais ? ' AND IsConverted = true' : ' AND IsConverted = false')
      : (terminais ? ' AND IsClosed = true' : ' AND IsClosed = false');
    String q =
      'SELECT Id, ' +
      campoAntigo +
      ', ' +
      campoNovo +
      ' FROM ' +
      objeto +
      ' WHERE RecordType.DeveloperName = \'SOL\' AND ' +
      campoAntigo +
      ' != null' +
      filtroAtivo;
    return Database.getQueryLocator(q);
  }

  public void execute(Database.BatchableContext bc, List<SObject> escopo) {
    List<SObject> paraAtualizar = new List<SObject>();
    for (SObject r : escopo) {
      String antigo = (String) r.get(campoAntigo);
      String novo = (String) r.get(campoNovo);
      // Só migra quando o novo ainda está vazio: idempotente e não sobrescreve
      // seleção múltipla feita depois da migração.
      if (String.isNotBlank(antigo) && String.isBlank(novo)) {
        r.put(campoNovo, antigo);
        paraAtualizar.add(r);
      }
    }
    if (!paraAtualizar.isEmpty()) {
      // Sucesso parcial: uma linha problemática (ex.: automação de borda) não
      // derruba a migração do lote inteiro. Falhas ficam no resultado do job.
      Database.update(paraAtualizar, false);
    }
  }

  public void finish(Database.BatchableContext bc) {
  }
}
